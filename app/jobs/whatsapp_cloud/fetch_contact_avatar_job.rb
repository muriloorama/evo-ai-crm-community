class WhatsappCloud::FetchContactAvatarJob < ApplicationJob
  queue_as :low

  def perform(contact_id, phone_number)
    contact = Contact.find(contact_id)
    return if contact.avatar.attached?

    # Check if Evolution Go is configured in Admin settings
    return unless evolution_go_configured?

    phone_without_plus = phone_number.gsub(/^\+/, '')
    profile_picture_url = fetch_profile_picture_from_evolution_go(phone_without_plus)

    if profile_picture_url.present?
      Avatar::AvatarFromUrlJob.perform_later(contact, profile_picture_url)
      Rails.logger.info "WhatsApp Cloud: Evolution Go profile picture scheduled for contact #{contact.id}"
    end
  rescue StandardError => e
    Rails.logger.error "WhatsApp Cloud: Avatar fetch failed for contact #{contact_id}: #{e.message}"
  end

  private

  def evolution_go_configured?
    api_url = GlobalConfigService.load('EVOLUTION_GO_API_URL', '')
    instance_token = GlobalConfigService.load('EVOLUTION_GO_INSTANCE_SECRET', '')

    api_url.present? && instance_token.present?
  end

  def fetch_profile_picture_from_evolution_go(phone_number)
    api_url = GlobalConfigService.load('EVOLUTION_GO_API_URL', '')
    instance_token = GlobalConfigService.load('EVOLUTION_GO_INSTANCE_SECRET', '')

    Rails.logger.debug { "WhatsApp Cloud: Calling Evolution Go /user/avatar for number #{phone_number}" }

    avatar_url = "#{api_url}/user/avatar"

    request_body = {
      number: phone_number,
      preview: false
    }

    uri = URI.parse(avatar_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 10

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = instance_token
    request['Content-Type'] = 'application/json'
    request.body = request_body.to_json

    Rails.logger.debug { "WhatsApp Cloud: Avatar request - URL: #{avatar_url}" }

    response = http.request(request)
    Rails.logger.debug { "WhatsApp Cloud: Avatar response - Code: #{response.code}" }

    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.warn "WhatsApp Cloud: Avatar request failed - Status: #{response.code}"
      return nil
    end

    response_data = JSON.parse(response.body)

    # Extract URL from Evolution Go response format
    profile_picture_url = response_data.dig('data', 'url')

    if profile_picture_url.present?
      Rails.logger.info 'WhatsApp Cloud: Profile picture URL retrieved via Evolution Go'
      profile_picture_url
    else
      Rails.logger.debug { "WhatsApp Cloud: No profile picture available for phone #{phone_number}" }
      nil
    end
  rescue JSON::ParserError => e
    Rails.logger.error "WhatsApp Cloud: Avatar response JSON parse error: #{e.message}"
    nil
  rescue StandardError => e
    Rails.logger.error "WhatsApp Cloud: Avatar request error: #{e.class} - #{e.message}"
    nil
  end
end
