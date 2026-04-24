class Api::V1::Uazapi::QrcodesController < Api::V1::BaseController
  # GET → retorna QR code atual da instância (após conectar)
  # POST → força refresh, pedindo um novo QR code (chama /instance/connect)
  def show
    channel = find_channel(params[:id])
    return render_not_found(params[:id]) unless channel

    result = fetch_qrcode(channel)
    Rails.logger.info "Uazapi qrcode show: base64_len=#{result[:base64]&.length}, connected=#{result[:connected]}"
    # Retornamos em múltiplos formatos pra compatibilidade: a tela do Evolution aceita
    # tanto `response.base64` (nível raiz) quanto `response.data.base64` (nested).
    render json: result.merge(success: true, data: result)
  rescue StandardError => e
    Rails.logger.error "Uazapi qrcode show error: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def create
    auth = params[:qrcode] || params
    api_url = auth[:api_url].presence || GlobalConfigService.load('UAZAPI_API_URL', '').to_s.strip
    instance_token = auth[:instance_token].to_s.strip
    phone = auth[:phone_number].to_s.strip

    if api_url.blank? || instance_token.blank?
      return render json: { error: 'api_url and instance_token required' }, status: :bad_request
    end

    render json: { success: true, qrcode: request_qrcode(api_url, instance_token, phone) }
  rescue StandardError => e
    Rails.logger.error "Uazapi qrcode refresh error: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def find_channel(instance_ref)
    Channel::Whatsapp.joins(:inbox).where(provider: 'uazapi').find do |ch|
      config = ch.provider_config || {}
      [config['instance_name'], config['instance_token'], ch.inbox&.name].compact.include?(instance_ref)
    end
  end

  def render_not_found(instance_ref)
    render json: { error: "Channel not found for instance: #{instance_ref}" }, status: :not_found
  end

  def fetch_qrcode(channel)
    config = channel.provider_config
    api_url = config['api_url'].presence || GlobalConfigService.load('UAZAPI_API_URL', '').to_s.strip
    token = config['instance_token'] || config['token']
    request_qrcode(api_url, token, channel.phone_number)
  end

  def request_qrcode(api_url, instance_token, _phone_number = nil)
    # Nunca enviamos o phone — com phone a UAZAPI entra no fluxo de pairing code em
    # vez de QR Code. Sempre forçamos QR.
    body = {}
    headers = { 'token' => instance_token, 'Content-Type' => 'application/json' }
    url = "#{api_url.chomp('/')}/instance/connect"

    # A UAZAPI frequentemente retorna QR vazio na primeira chamada logo após criar a
    # instância (ainda está gerando). Fazemos até 4 tentativas com 1.2s de intervalo
    # antes de devolver resposta vazia.
    qrcode = ''
    pairing = nil
    connected = false

    4.times do |attempt|
      response = HTTParty.post(url, headers: headers, body: body.to_json, timeout: 30)
      raise "Failed to get QR code: #{response.code} - #{response.body}" unless response.success?

      parsed = response.parsed_response
      instance = parsed['instance'] || {}

      if parsed['connected'] == true || parsed['loggedIn'] == true
        return { connected: true, state: 'open' }
      end

      qrcode = instance['qrcode'].to_s
      pairing = instance['paircode']
      connected = false

      break if qrcode.present?

      Rails.logger.info "Uazapi qrcode: empty on attempt #{attempt + 1}/4, retrying..."
      sleep 1.2
    end

    # Mantém o data URI completo — o frontend usa direto como <img src={qrCode} />.
    {
      base64: qrcode,
      pairingCode: pairing,
      connected: connected
    }
  end
end
