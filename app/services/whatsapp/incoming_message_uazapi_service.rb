# Reusa toda a máquina do Evolution (handlers de upsert/update, content handlers,
# attachment processor) traduzindo o payload UAZAPI ao formato Evolution/Baileys.
#
# Formato real observado em produção (ignora a doc OpenAPI, que é outra variante):
#
#   POST /webhook
#   {
#     "EventType": "messages" | "messages_update" | "connection" | "presence" | ...,
#     "instanceName": "<nome>",
#     "owner": "<numero-dono-da-instancia>",
#     "message": { ...payload de mensagem... },   # em EventType=messages
#     "event": { ...dados de outros eventos... },  # em presence/connection
#     "chat": { ... }                              # metadata da conversa
#   }
#
# Traduzindo aqui para o schema Baileys que os handlers Evolution já sabem consumir,
# evitamos duplicar ~1.000 linhas de código.
class Whatsapp::IncomingMessageUazapiService < Whatsapp::IncomingMessageEvolutionService
  private

  def processed_params
    @processed_params ||= begin
      # Opportunistic caching: every uazapi webhook carries the instance
      # owner's phone number. Persist it once so the Canais UI can show
      # the real number instead of the "+uazapi-..." placeholder.
      cache_owner_phone_number(params)
      translate_uazapi_payload(params)
    end
  end

  def cache_owner_phone_number(payload)
    return unless inbox&.channel&.provider_config
    return if inbox.channel.provider_config['owner_phone_number'].present?

    owner = payload[:owner] || payload['owner']
    return if owner.blank?

    formatted = "+#{owner.to_s.delete('+')}"
    config = inbox.channel.provider_config.dup
    config['owner_phone_number'] = formatted
    inbox.channel.update_columns(provider_config: config)
  rescue StandardError => e
    Rails.logger.warn "Uazapi: failed to cache owner_phone_number: #{e.message}"
  end

  # Após conectar com sucesso, força a instância a ficar "unavailable" — isso garante
  # que o celular continue recebendo notificações (o WhatsApp silencia o celular quando
  # enxerga uma sessão Web ativa).
  def handle_connection_open(profile_picture_url)
    super
    inbox.channel.update_presence('unavailable')
  rescue StandardError => e
    Rails.logger.error "Uazapi: failed to set presence after connect: #{e.message}"
  end

  # UAZAPI envia `chat.imagePreview` em cada webhook de mensagem. Usamos isso para
  # baixar e anexar o avatar ao contato automaticamente.
  def handle_message
    return if drop_due_to_groups_ignore?
    super
    attach_contact_avatar_if_available
    capture_tracking_source_if_first_touch if incoming?
  end

  # The upstream Evolution handler's message_processable? hard-rejects anything
  # whose JID isn't a regular user (`@s.whatsapp.net`). uazapi delivers group
  # messages too, so we override here to allow `group` JIDs through whenever
  # the operator hasn't explicitly opted out via `groupsIgnore`.
  def message_processable?
    return false if jid_type != 'user' && jid_type != 'group'
    return false if jid_type == 'group' && ignore_groups?
    return false if jid_type == 'group' && locked_group?
    return false if ignore_message?
    return false if find_message_by_source_id(raw_message_id) || message_under_process?

    true
  end

  # Per-group lock: even with `groupsIgnore` off, an operator can silence a
  # specific group via the conversation menu. Persisted on Contact so the lock
  # survives conversation resolve/reopen but disappears if the contact is
  # deleted (matches user request: "se o grupo for apagado, ele volta a receber").
  def locked_group?
    group_jid = @raw_message&.dig(:key, :remoteJid).to_s
    return false if group_jid.blank?

    group_id  = group_jid.split('@').first
    source_id = "GR.#{group_id}"

    contact_inbox = inbox.contact_inboxes.find_by(source_id: source_id)
    return false unless contact_inbox

    locked = contact_inbox.contact&.additional_attributes&.dig('group_locked')
    if locked
      Rails.logger.info "Uazapi: dropping group message — group #{group_id} is locked (contact #{contact_inbox.contact_id})"
      true
    else
      false
    end
  end

  # For groups, anchor the ContactInbox on the group's ID (not the sender's
  # phone). Group JIDs (18-digit @g.us) don't fit the WhatsApp source_id
  # phone-number validation, so we encode them as `GR.<id>` which the
  # `[A-Z]{2}\.[a-zA-Z0-9]+` branch of the validator accepts.
  def set_contact
    return super unless jid_type == 'group'

    group_jid    = @raw_message.dig(:key, :remoteJid).to_s
    group_id     = group_jid.split('@').first
    group_name   = group_display_name
    source_id    = "GR.#{group_id}"

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: source_id,
      inbox: inbox,
      contact_attributes: {
        name: group_name.presence || "Grupo #{group_id}",
        phone_number: nil
      }
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact

    # Keep the contact name in sync with the group title even if it was
    # initialised from a placeholder on a previous message.
    if group_name.present? && @contact.name != group_name
      @contact.update(name: group_name)
    end
  end

  def group_display_name
    raw = params[:message] || params['message'] || {}
    chat = params[:chat] || params['chat'] || {}
    raw[:groupName].presence ||
      raw['groupName'].presence ||
      chat[:name].presence ||
      chat['name'].presence ||
      chat[:wa_name].presence ||
      chat['wa_name'].presence
  end

  # Honor the `groupsIgnore` flag set in the channel's instance_settings.
  # uazapi delivers everything (groups + DMs) and we filter on our side, so
  # this becomes the canonical "no group conversations" toggle.
  def drop_due_to_groups_ignore?
    return false unless ignore_groups?
    return false unless from_group?

    Rails.logger.info "Uazapi: dropping group message — groupsIgnore enabled for inbox #{inbox.id}"
    true
  end

  def ignore_groups?
    inbox&.channel&.provider_config&.dig('instance_settings', 'groupsIgnore') == true
  end

  def from_group?
    chat = params[:chat] || params['chat'] || {}
    msg  = params[:message] || params['message'] || {}
    return true if truthy?(chat[:wa_isGroup]) || truthy?(chat['wa_isGroup'])
    return true if truthy?(msg[:isGroup])     || truthy?(msg['isGroup'])

    chatid = (msg[:chatid] || msg['chatid'] || chat[:wa_chatid] || chat['wa_chatid']).to_s
    chatid.end_with?('@g.us')
  end

  def attach_contact_avatar_if_available
    return unless @contact

    pic_url = params.dig(:chat, :imagePreview).presence ||
              params.dig('chat', 'imagePreview').presence
    return if pic_url.blank?
    return if @contact.avatar.attached?

    Rails.logger.info "Uazapi: downloading avatar for contact #{@contact.id} from #{pic_url}"
    require 'open-uri'
    downloaded = URI.parse(pic_url).open(read_timeout: 15)
    @contact.avatar.attach(
      io: downloaded,
      filename: "avatar_#{@contact.id}_#{Time.now.to_i}.jpg",
      content_type: 'image/jpeg'
    )
  rescue StandardError => e
    Rails.logger.warn "Uazapi: avatar download failed for contact #{@contact&.id}: #{e.message}"
  end

  def translate_uazapi_payload(payload)
    event_type = (payload[:EventType] || payload['EventType'] || payload[:type] || payload['type']).to_s
    instance = payload[:instanceName] || payload['instanceName'] || payload[:instance] || payload['instance']

    case event_type
    when 'messages', 'message'
      translate_message_upsert(instance, payload[:message] || payload['message'] || {})
    when 'messages_update'
      translate_message_update(instance, payload[:message] || payload['message'] || payload[:event] || payload['event'] || {})
    when 'connection'
      translate_connection_update(instance, payload[:event] || payload['event'] || payload)
    when 'presence'
      { event: 'presence.update', instance: instance, data: (payload[:event] || payload['event']) }.with_indifferent_access
    else
      { event: event_type, instance: instance, data: payload }.with_indifferent_access
    end
  end

  def translate_message_upsert(instance, msg)
    msg = msg.to_unsafe_h if msg.respond_to?(:to_unsafe_h)
    msg = msg.with_indifferent_access

    key = {
      remoteJid: msg[:chatid].presence || build_jid_from_sender(msg),
      id: msg[:messageid].presence || msg[:id],
      fromMe: truthy?(msg[:fromMe])
    }

    body = build_baileys_message(msg)

    # O attachment_processor do Evolution baixa a mídia a partir de `message.mediaUrl`.
    # Aninhamos aí a URL resolvida (via /message/download da UAZAPI) quando for mídia.
    media_url = body.values.find { |v| v.is_a?(Hash) && v[:url] }&.dig(:url)
    msg_data = { key: key,
                 pushName: msg[:senderName].presence || msg[:pushName],
                 messageTimestamp: normalize_timestamp(msg[:messageTimestamp] || msg[:timestamp]),
                 message: body }
    msg_data[:message][:mediaUrl] = media_url if media_url.present?

    Rails.logger.info "Uazapi translator: messageType=#{msg[:messageType]}, baileys_keys=#{body.keys.inspect}, mediaUrl=#{media_url.present?}"

    { event: 'messages.upsert', instance: instance, data: msg_data }.with_indifferent_access
  end

  def translate_message_update(instance, msg)
    msg = msg.with_indifferent_access
    status = map_uazapi_status(msg[:status])
    id = msg[:messageid].presence || msg[:id]
    remote_jid = msg[:chatid].presence || build_jid_from_sender(msg)

    {
      event: 'messages.update',
      instance: instance,
      data: {
        keyId: id,
        key: { id: id, remoteJid: remote_jid, fromMe: truthy?(msg[:fromMe]) },
        status: status,
        update: { status: status }
      }
    }.with_indifferent_access
  end

  def translate_connection_update(instance, data)
    data = (data || {}).with_indifferent_access
    connected = truthy?(data[:connected]) || truthy?(data[:loggedIn]) ||
                data[:status].to_s.downcase.include?('connect') ||
                data[:State].to_s.downcase == 'open'

    {
      event: 'connection.update',
      instance: instance,
      data: {
        state: connected ? 'open' : 'close',
        statusReason: data[:statusReason] || data[:reason],
        profilePictureUrl: data[:profilePictureUrl] || data[:imagePreview]
      }
    }.with_indifferent_access
  end

  def build_jid_from_sender(msg)
    sender = msg[:sender_pn].presence || msg[:sender].presence || msg[:from].presence || msg[:number]
    return sender if sender.to_s.include?('@')

    is_group = truthy?(msg[:isGroup]) || truthy?(msg[:IsGroup])
    "#{sender}#{is_group ? '@g.us' : '@s.whatsapp.net'}"
  end

  # UAZAPI manda timestamps em segundos OU milissegundos. Os handlers esperam segundos.
  def normalize_timestamp(ts)
    return Time.now.to_i if ts.nil?

    value = ts.to_i
    value > 10_000_000_000 ? value / 1000 : value
  end

  def truthy?(v)
    v == true || v.to_s.downcase == 'true'
  end

  # Converte a estrutura UAZAPI em payload Baileys-shaped (`message.conversation`, etc)
  def build_baileys_message(msg)
    type = msg[:messageType].to_s.downcase
    text = extract_text(msg)
    content = msg[:content]

    case type
    when 'conversation', 'text', 'textmessage', ''
      { conversation: text }
    when 'extendedtextmessage', 'extendedtext'
      { extendedTextMessage: { text: text } }
    when 'imagemessage', 'image'
      { imageMessage: { caption: text, url: media_url_from(msg), mimetype: msg[:mimetype] } }
    when 'videomessage', 'video'
      { videoMessage: { caption: text, url: media_url_from(msg), mimetype: msg[:mimetype] } }
    when 'audiomessage', 'audio'
      { audioMessage: { url: media_url_from(msg), mimetype: msg[:mimetype], ptt: false } }
    when 'pttmessage', 'ptt'
      { audioMessage: { url: media_url_from(msg), mimetype: msg[:mimetype] || 'audio/ogg; codecs=opus', ptt: true } }
    when 'documentmessage', 'document'
      filename = content.is_a?(Hash) ? content['fileName'] || content[:fileName] : nil
      { documentMessage: { caption: text, url: media_url_from(msg), mimetype: msg[:mimetype], fileName: filename } }
    when 'stickermessage', 'sticker'
      { stickerMessage: { url: media_url_from(msg), mimetype: msg[:mimetype] } }
    when 'locationmessage', 'location'
      { locationMessage: { degreesLatitude: msg[:latitude], degreesLongitude: msg[:longitude], name: msg[:locationName], address: msg[:address] } }
    when 'reactionmessage', 'reaction'
      # Translate to Baileys reactionMessage so the Evolution handler picks it
      # up as a reaction (sets is_reaction + in_reply_to_external_id linking
      # to the original message). UAZAPI ships the emoji in `text`/`content.text`
      # and the target message id in `reaction` (or sender/quoted variants).
      target_id = extract_reaction_target_id(msg)
      emoji     = extract_reaction_emoji(msg)
      { reactionMessage: { text: emoji, key: { id: target_id } } }
    else
      { conversation: text.presence || "[#{type}]" }
    end
  end

  def extract_reaction_emoji(msg)
    content = msg[:content]
    if content.is_a?(Hash) || content.is_a?(ActionController::Parameters)
      c = content.respond_to?(:with_indifferent_access) ? content.with_indifferent_access : content
      candidate = c[:reaction] || c[:emoji] || c[:text]
      return candidate.to_s if candidate.present?
    end
    return msg[:text].to_s if msg[:text].present? && !looks_like_message_id?(msg[:text])

    ''
  end

  def extract_reaction_target_id(msg)
    content = msg[:content]
    if content.is_a?(Hash) || content.is_a?(ActionController::Parameters)
      c = content.respond_to?(:with_indifferent_access) ? content.with_indifferent_access : content
      candidate = c[:targetMessageId] || c[:messageId] || c[:quotedMessageId] || c.dig(:key, :id)
      return candidate.to_s if candidate.present?
    end
    candidate = msg[:reaction] || msg[:targetMessageId] || msg[:quotedMessageId] || msg.dig(:quoted, :messageid)
    candidate.to_s if candidate.present?
  end

  def looks_like_message_id?(value)
    value.to_s.match?(/\A[A-F0-9]{16,}\z/)
  end

  def extract_text(msg)
    return msg[:text].to_s if msg[:text].present?

    content = msg[:content]
    if content.is_a?(Hash) || content.is_a?(ActionController::Parameters)
      c = content.respond_to?(:with_indifferent_access) ? content.with_indifferent_access : content
      return (c[:text] || c['text']).to_s if c.is_a?(Hash) || c.is_a?(ActionController::Parameters)
    end
    content.is_a?(String) ? content : ''
  end

  def media_url_from(msg)
    # A URL que a UAZAPI coloca em `content.URL` aponta para o CDN WhatsApp e o arquivo
    # vem encriptado com a mediaKey. Para o CRM baixar, precisamos chamar
    # `POST /message/download` que devolve uma URL pública descriptografada.
    resolved = resolve_via_download(msg[:messageid].presence || msg[:id])
    return resolved if resolved.present?

    # Fallback: URLs simples (raramente presentes)
    return msg[:fileUrl] if msg[:fileUrl].present?
    return msg[:url] if msg[:url].present?

    content = msg[:content]
    return nil unless content.is_a?(Hash) || content.is_a?(ActionController::Parameters)

    c = content.respond_to?(:with_indifferent_access) ? content.with_indifferent_access : content
    c[:URL] || c[:url] || c[:directPath] || c[:fileUrl]
  end

  def resolve_via_download(message_id)
    return nil if message_id.blank?

    config = inbox.channel.provider_config
    api_url = (config['api_url'].presence || GlobalConfigService.load('UAZAPI_API_URL', '').to_s.strip).to_s.chomp('/')
    token = config['instance_token'] || config['token']
    return nil if api_url.blank? || token.blank?

    response = HTTParty.post(
      "#{api_url}/message/download",
      headers: { 'token' => token, 'Content-Type' => 'application/json' },
      body: { id: message_id }.to_json,
      timeout: 30
    )
    return nil unless response.success?

    parsed = response.parsed_response.is_a?(Hash) ? response.parsed_response : {}
    url = parsed['fileURL'] || parsed['fileUrl'] || parsed['url']
    Rails.logger.info "Uazapi: resolved media URL for #{message_id}" if url
    url
  rescue StandardError => e
    Rails.logger.error "Uazapi: media download error for #{message_id}: #{e.message}"
    nil
  end

  def map_uazapi_status(status)
    case status.to_s.downcase
    when 'queued' then 'PENDING'
    when 'sent' then 'SERVER_ACK'
    when 'delivered' then 'DELIVERY_ACK'
    when 'read' then 'READ'
    when 'failed' then 'ERROR'
    else status
    end
  end
end
