## Avisa via UAZAPI quando um lead novo chega (nova conversa) numa conta específica.
## Configuração por ENV — ver bloco "Lead Notification" no .env da raiz.
class LeadNotificationListener < BaseListener
  def conversation_created(event)
    return unless enabled?

    conversation = event.data[:conversation]
    return unless conversation
    return unless target_account?(conversation.account_id)

    deliver(conversation)
  rescue StandardError => e
    Rails.logger.error "[LeadNotificationListener] failed: #{e.class} - #{e.message}"
  end

  private

  def enabled?
    ENV.fetch('LEAD_NOTIFY_ENABLED', 'false').to_s.downcase == 'true' &&
      uazapi_url.present? && uazapi_token.present? && target_number.present?
  end

  # Account lives in the accounts table but has no local AR model here
  # (see broadcast_campaign.rb:42). Raw query is the simplest path.
  def target_account?(account_id)
    return false if account_id.blank?

    expected = ENV.fetch('LEAD_NOTIFY_ACCOUNT_NUMBER', '').to_s.strip
    return false if expected.blank?

    number = ApplicationRecord.connection.select_value(
      ApplicationRecord.sanitize_sql_for_conditions(['SELECT number FROM accounts WHERE id = ? LIMIT 1', account_id])
    )
    number.to_s == expected
  end

  def deliver(conversation)
    response = HTTParty.post(
      "#{uazapi_url.chomp('/')}/send/text",
      headers: { 'token' => uazapi_token, 'Content-Type' => 'application/json', 'Accept' => 'application/json' },
      body: { number: target_number, text: message_text(conversation) }.to_json,
      timeout: 15
    )
    return if response.success?

    Rails.logger.warn "[LeadNotificationListener] uazapi #{response.code}: #{response.body.to_s.truncate(300)}"
  end

  def message_text(conversation)
    contact = conversation.contact
    inbox   = conversation.inbox
    first   = conversation.messages.incoming.order(:created_at).first

    lines = [
      '🆕 *Lead novo*',
      "Nome: #{contact&.name.presence || 'sem nome'}",
      "Telefone: #{contact&.phone_number.presence || '-'}",
      "Canal: #{inbox&.name}",
      "Conversa: ##{conversation.display_id}"
    ]
    lines << "Mensagem: #{first.content.to_s.truncate(240)}" if first&.content.present?
    lines.join("\n")
  end

  def uazapi_url
    ENV.fetch('LEAD_NOTIFY_UAZAPI_URL', nil)
  end

  def uazapi_token
    ENV.fetch('LEAD_NOTIFY_UAZAPI_TOKEN', nil)
  end

  def target_number
    ENV.fetch('LEAD_NOTIFY_TARGET_NUMBER', '').to_s.delete('+').strip
  end
end
