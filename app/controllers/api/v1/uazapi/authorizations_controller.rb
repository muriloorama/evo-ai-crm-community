class Api::V1::Uazapi::AuthorizationsController < Api::V1::BaseController
  # Cria uma instância UAZAPI (requer admintoken), registra o canal WhatsApp
  # com o token retornado e dispara a configuração do webhook.
  def create
    auth = params[:authorization] || params

    # Fallback para a config global quando o frontend não envia (UX "sem UAZAPI exposto"):
    # o admin seta UAZAPI_API_URL e UAZAPI_ADMIN_SECRET no .env e o cliente nem vê esses campos.
    api_url = auth[:api_url].presence || GlobalConfigService.load('UAZAPI_API_URL', '').to_s.strip
    admin_token = auth[:admin_token].presence || GlobalConfigService.load('UAZAPI_ADMIN_SECRET', '').to_s.strip
    instance_name = auth[:instance_name].to_s.strip
    # phone_number é opcional: quando ausente, o canal é criado com placeholder único
    # e o número real é descoberto depois do QR ser escaneado (via webhook de conexão).
    phone_number = auth[:phone_number].to_s.strip
    phone_number = "+uazapi-#{SecureRandom.hex(6)}" if phone_number.blank?

    missing = []
    missing << 'api_url' if api_url.blank?
    missing << 'admin_token' if admin_token.blank?
    missing << 'instance_name' if instance_name.blank?

    if missing.any?
      return error_response(
        ApiErrorCodes::MISSING_REQUIRED_FIELD,
        "Missing required parameters: #{missing.join(', ')}",
        status: :bad_request
      )
    end

    response = HTTParty.post(
      "#{api_url.chomp('/')}/instance/create",
      headers: {
        'admintoken' => admin_token,
        'Content-Type' => 'application/json'
      },
      body: { name: instance_name }.to_json,
      timeout: 30
    )

    unless response.success?
      Rails.logger.error "Uazapi create instance failed: #{response.code} - #{response.body}"
      return error_response(
        ApiErrorCodes::EXTERNAL_SERVICE_ERROR,
        "Failed to create instance: #{response.code}",
        status: :unprocessable_entity
      )
    end

    parsed = response.parsed_response
    instance_token = parsed['token'] || parsed.dig('instance', 'token')

    if instance_token.blank?
      return error_response(
        ApiErrorCodes::EXTERNAL_SERVICE_ERROR,
        'Instance created but no token returned',
        status: :unprocessable_entity
      )
    end

    success_response(
      data: {
        instance: parsed['instance'] || {},
        instance_token: instance_token,
        instance_name: instance_name,
        api_url: api_url,
        phone_number: phone_number
      },
      message: 'Instance created successfully'
    )
  rescue StandardError => e
    Rails.logger.error "Uazapi authorization error: #{e.class} - #{e.message}"
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end
end
