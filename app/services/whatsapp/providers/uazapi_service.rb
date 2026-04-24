require 'base64'

class Whatsapp::Providers::UazapiService < Whatsapp::Providers::BaseService
  def send_message(phone_number, message)
    @message = message
    @phone_number = phone_number

    if message.attachments.present?
      send_attachment_message(phone_number, message)
    elsif message.content.present?
      send_text_message(phone_number, message)
    else
      @message.update!(is_unsupported: true)
      nil
    end
  end

  def send_template(phone_number, template_info)
    send_text_message(phone_number, build_template_text(template_info))
  end

  def sync_templates
    Rails.logger.debug 'Uazapi: templates managed internally, no external sync'
  end

  def create_template(template_data)
    internal_template = {
      'id' => SecureRandom.uuid,
      'name' => template_data['name'],
      'category' => template_data['category'],
      'language' => template_data['language'],
      'status' => 'APPROVED',
      'components' => template_data['components'],
      'created_at' => Time.current.iso8601,
      'updated_at' => Time.current.iso8601
    }
    internal_template
  end

  def update_template(template_id, template_data)
    {
      'id' => template_id,
      'name' => template_data['name'],
      'category' => template_data['category'],
      'language' => template_data['language'],
      'components' => template_data['components'],
      'updated_at' => Time.current.iso8601
    }
  end

  def delete_template(_template_name)
    true
  end

  def validate_provider_config?
    return false if api_base_path.blank? || instance_token.blank?

    response = HTTParty.get(
      "#{api_base_path}/instance/status",
      headers: api_headers,
      timeout: 10
    )

    response.success?
  rescue StandardError => e
    Rails.logger.error "Uazapi validation error: #{e.message}"
    false
  end

  def api_headers
    {
      'token' => instance_token.to_s,
      'Content-Type' => 'application/json'
    }
  end

  def admin_headers
    {
      'admintoken' => admin_token.to_s,
      'Content-Type' => 'application/json'
    }
  end

  def media_url(media_id)
    "#{api_base_path}/message/download/#{media_id}"
  end

  def subscribe_to_webhooks
    token = whatsapp_channel.provider_config['webhook_verify_token']
    backend_url = ENV.fetch('BACKEND_URL', nil).presence || ENV.fetch('FRONTEND_URL', '').to_s
    webhook_url = "#{backend_url.chomp('/')}/api/v1/webhooks/uazapi/#{token}"

    Rails.logger.info "Uazapi: subscribing webhook to #{webhook_url}"
    response = HTTParty.post(
      "#{api_base_path}/webhook",
      headers: api_headers,
      body: {
        enabled: true,
        url: webhook_url,
        events: %w[messages messages_update connection presence contacts chats],
        excludeMessages: %w[wasSentByApi]
      }.to_json,
      timeout: 15
    )
    Rails.logger.info "Uazapi subscribe response: #{response.code}"
  rescue StandardError => e
    Rails.logger.error "Uazapi subscribe webhook error: #{e.message}"
  end

  def unsubscribe_from_webhooks
    HTTParty.post(
      "#{api_base_path}/webhook",
      headers: api_headers,
      body: { enabled: false }.to_json,
      timeout: 15
    )
  rescue StandardError => e
    Rails.logger.error "Uazapi unsubscribe webhook error: #{e.message}"
  end

  def disconnect_channel_provider
    return if instance_token.blank?

    # Ordem importa: desconectar primeiro (fecha a sessão no WhatsApp) e depois deletar
    # a instância (remove do banco do UAZAPI). Ambos usam o token da instância.
    HTTParty.post("#{api_base_path}/instance/disconnect", headers: api_headers, timeout: 15)
    HTTParty.delete("#{api_base_path}/instance", headers: api_headers, timeout: 15)
    Rails.logger.info "Uazapi: instance #{whatsapp_channel.provider_config['instance_name']} disconnected and deleted"
  rescue StandardError => e
    Rails.logger.error "Uazapi disconnect/delete error: #{e.message}"
  end

  # Define a presença global da instância (available / unavailable).
  # Chamado automaticamente após conexão para deixar o WhatsApp "offline" no Web —
  # assim o celular continua recebendo notificações normalmente.
  def update_presence(status)
    presence = status.to_s.in?(%w[available unavailable]) ? status.to_s : 'unavailable'

    Rails.logger.info "Uazapi: setting instance presence to #{presence}"
    HTTParty.post(
      "#{api_base_path}/instance/presence",
      headers: api_headers,
      body: { presence: presence }.to_json,
      timeout: 10
    )
  rescue StandardError => e
    Rails.logger.error "Uazapi update_presence error: #{e.message}"
  end

  def toggle_typing_status(phone_number, typing_status)
    presence = typing_status == Events::Types::CONVERSATION_TYPING_ON ? 'composing' : 'paused'
    HTTParty.post(
      "#{api_base_path}/message/presence",
      headers: api_headers,
      body: {
        number: phone_number.delete('+'),
        presence: presence,
        delay: 25_000
      }.to_json,
      timeout: 10
    )
  rescue StandardError => e
    Rails.logger.error "Uazapi typing error: #{e.message}"
  end

  def read_messages(_phone_number, messages)
    ids = messages.map { |m| m.source_id.presence }.compact
    return if ids.empty?

    HTTParty.post(
      "#{api_base_path}/message/markread",
      headers: api_headers,
      body: { id: ids }.to_json,
      timeout: 10
    )
  rescue StandardError => e
    Rails.logger.error "Uazapi mark-read error: #{e.message}"
  end

  def api_base_path
    url = whatsapp_channel.provider_config['api_url'].presence ||
          GlobalConfigService.load('UAZAPI_API_URL', '').to_s.strip
    url.to_s.chomp('/')
  end

  def instance_token
    whatsapp_channel.provider_config['instance_token'].presence ||
      whatsapp_channel.provider_config['token']
  end

  def admin_token
    whatsapp_channel.provider_config['admin_token'].presence ||
      GlobalConfigService.load('UAZAPI_ADMIN_SECRET', '').to_s.strip
  end

  private

  def send_text_message(phone_number, message)
    raw_content = message.respond_to?(:content) ? message.content : message.to_s

    response = HTTParty.post(
      "#{api_base_path}/send/text",
      headers: api_headers,
      body: {
        number: phone_number.delete('+'),
        text: html_to_whatsapp(raw_content),
        linkPreview: true
      }.to_json,
      timeout: 30
    )

    process_send_response(response)
  end

  def send_attachment_message(phone_number, message)
    attachment = message.attachments.first
    return unless attachment

    uazapi_type = map_attachment_type(attachment)
    send_media_message(phone_number, message, attachment, uazapi_type)
  end

  def map_attachment_type(attachment)
    case attachment.file_type
    when 'image' then 'image'
    when 'video' then 'video'
    when 'audio' then voice_note?(attachment) ? 'ptt' : 'myaudio'
    when 'file'  then 'document'
    else 'document'
    end
  end

  def voice_note?(attachment)
    content_type = attachment.file.attached? ? attachment.file.content_type.to_s : ''
    content_type.include?('ogg') || content_type.include?('opus') || attachment.meta.to_h['is_recorded_audio']
  end

  def send_media_message(phone_number, message, attachment, uazapi_type)
    media_source = generate_direct_s3_url(attachment)

    body = {
      number: phone_number.delete('+'),
      type: uazapi_type,
      file: media_source,
      text: html_to_whatsapp(message.content.to_s)
    }

    if uazapi_type == 'document'
      body[:docName] = attachment.file.filename.to_s
      body[:mimetype] = attachment.file.attached? ? attachment.file.content_type.to_s : nil
    end

    response = HTTParty.post(
      "#{api_base_path}/send/media",
      headers: api_headers,
      body: body.compact.to_json,
      timeout: 60
    )

    result = process_send_response(response)

    if !result && attachment.file.attached?
      Rails.logger.info '[Uazapi Media] URL failed, retrying with base64'
      result = send_media_with_base64(phone_number, message, attachment, uazapi_type)
    end

    result
  end

  def send_media_with_base64(phone_number, message, attachment, uazapi_type)
    file_b64 = Base64.strict_encode64(attachment.file.download)

    body = {
      number: phone_number.delete('+'),
      type: uazapi_type,
      file: file_b64,
      text: html_to_whatsapp(message.content.to_s)
    }

    if uazapi_type == 'document'
      body[:docName] = attachment.file.filename.to_s
      body[:mimetype] = attachment.file.content_type.to_s
    end

    response = HTTParty.post(
      "#{api_base_path}/send/media",
      headers: api_headers,
      body: body.compact.to_json,
      timeout: 90
    )

    process_send_response(response)
  end

  def generate_direct_s3_url(attachment)
    return attachment.file_url unless attachment.file.attached?

    signed_url = attachment.download_url
    if signed_url =~ %r{https://([^/]+)/([^?]+)}
      "https://#{::Regexp.last_match(1)}/#{::Regexp.last_match(2)}"
    else
      signed_url
    end
  end

  def build_template_text(template_info)
    text = template_info[:name] || 'Template Message'
    Array(template_info[:parameters]).each_with_index do |param, i|
      text = text.gsub("{{#{i + 1}}}", param.to_s)
    end
    text
  end

  def process_send_response(response)
    if response.success?
      parsed = response.parsed_response.is_a?(Hash) ? response.parsed_response : {}
      return parsed['id'] || parsed['messageid'] || parsed.dig('response', 'messageid') || true
    end

    Rails.logger.error "Uazapi API error: #{response.code} - #{response.body}"
    false
  end
end
