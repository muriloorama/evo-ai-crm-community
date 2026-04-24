class Api::V1::Uazapi::InstancesController < Api::V1::BaseController
  def index
    instance_name = params[:instanceName].to_s.strip

    if instance_name.present?
      channel = find_channel(instance_name)
      return render_not_found(instance_name) unless channel

      render json: { success: true, data: fetch_status(channel) }
    else
      channels = Channel::Whatsapp.joins(:inbox).where(provider: 'uazapi')
      instances = channels.map do |ch|
        {
          instance_name: ch.provider_config['instance_name'],
          phone_number: ch.phone_number,
          api_url: ch.provider_config['api_url'],
          status: ch.provider_connection&.dig('connection') || 'unknown'
        }
      end
      render json: { success: true, data: instances }
    end
  rescue StandardError => e
    Rails.logger.error "Uazapi instances error: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def logout
    channel = find_channel(params[:id])
    return render_not_found(params[:id]) unless channel

    config = channel.provider_config
    api_url = (config['api_url'].presence || GlobalConfigService.load('UAZAPI_API_URL', '').to_s.strip).to_s.chomp('/')
    response = HTTParty.post(
      "#{api_url}/instance/disconnect",
      headers: { 'token' => config['instance_token'] || config['token'], 'Content-Type' => 'application/json' },
      timeout: 20
    )

    if response.success? || response.code.in?([400, 404])
      render json: { success: true, message: 'Instance logged out' }
    else
      render json: { error: "Logout failed: #{response.code}" }, status: :unprocessable_entity
    end
  rescue StandardError => e
    Rails.logger.error "Uazapi logout error: #{e.message}"
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

  def fetch_status(channel)
    config = channel.provider_config
    api_url = (config['api_url'].presence || GlobalConfigService.load('UAZAPI_API_URL', '').to_s.strip).to_s.chomp('/')
    response = HTTParty.get(
      "#{api_url}/instance/status",
      headers: { 'token' => config['instance_token'] || config['token'], 'Content-Type' => 'application/json' },
      timeout: 10
    )

    return { instance: { status: 'unknown' } } unless response.success?

    parsed = response.parsed_response
    status = parsed['status'] || {}

    {
      instance: {
        instanceName: config['instance_name'],
        connected: status['connected'] == true,
        loggedIn: status['loggedIn'] == true,
        jid: status['jid'],
        state: status['connected'] ? 'open' : 'close'
      }
    }
  end
end
