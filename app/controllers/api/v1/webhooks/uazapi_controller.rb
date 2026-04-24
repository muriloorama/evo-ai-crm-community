class Api::V1::Webhooks::UazapiController < ActionController::API
  # UAZAPI não implementa assinatura HMAC nem header de validação — a segurança
  # é feita pelo `webhook_token` que vai no path da URL e é gerado aleatoriamente
  # na criação do canal. O token é verificado aqui antes de enfileirar o job.
  def process_payload
    channel = find_channel_by_webhook_token(params[:webhook_token])

    unless channel
      Rails.logger.warn "Uazapi webhook: invalid or unknown token #{params[:webhook_token].to_s.first(6)}..."
      head :unauthorized
      return
    end

    Rails.logger.info "Uazapi webhook received for channel #{channel.phone_number} event=#{params[:event]}"

    payload = params.to_unsafe_hash.merge(uazapi: true, phone_number: channel.phone_number)
    Webhooks::WhatsappEventsJob.perform_later(payload)
    head :ok
  end

  private

  def find_channel_by_webhook_token(token)
    return nil if token.blank?

    Channel::Whatsapp
      .where(provider: 'uazapi')
      .where("provider_config ->> 'webhook_verify_token' = ?", token)
      .first
  end
end
