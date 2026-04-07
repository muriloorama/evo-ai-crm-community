module Whatsapp::EvolutionGoHandlers::ProfilePictureHandler
  include Whatsapp::EvolutionGoHandlers::Helpers

  private

  def update_contact_profile_picture(contact, phone_number)
    return if contact.avatar.attached?
    return unless should_fetch_profile_picture?

    # Determine primary and fallback numbers for avatar fetch
    primary_number, fallback_number = determine_avatar_fetch_numbers(contact, phone_number)

    Rails.logger.info "Evolution Go API: Scheduling avatar fetch for contact #{contact.id} (primary: #{primary_number}, fallback: #{fallback_number})"

    # Use global configuration if available, otherwise fall back to channel config
    if global_evolution_go_configured?
      Rails.logger.info "Evolution Go API: Using global configuration for avatar fetch"
      EvolutionGo::FetchContactAvatarWithFallbackJob.perform_later(
        contact.id,
        primary_number,
        fallback_number,
        global_api_base_url,
        global_instance_token
      )
    else
      Rails.logger.info "Evolution Go API: Using channel configuration for avatar fetch"
      EvolutionGo::FetchContactAvatarWithFallbackJob.perform_later(
        contact.id,
        primary_number,
        fallback_number,
        api_base_url,
        instance_token
      )
    end
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Failed to schedule avatar fetch for contact #{contact.id}: #{e.message}"
  end

  def determine_avatar_fetch_numbers(contact, phone_number)
    # If contact has identifier (SenderAlt), use it as primary and phone_number as fallback
    if contact.identifier.present?
      primary = contact.identifier
      fallback = phone_number
      Rails.logger.info "Evolution Go API: Using identifier '#{primary}' as primary, phone '#{fallback}' as fallback"
    else
      # No identifier available, use phone_number as primary only
      primary = phone_number
      fallback = nil
      Rails.logger.info "Evolution Go API: Using phone '#{primary}' as primary (no identifier available)"
    end

    [primary, fallback]
  end

  def should_fetch_profile_picture?
    # Check global config first, then channel config
    global_evolution_go_configured? || channel_evolution_go_configured?
  end

  def global_evolution_go_configured?
    global_api_base_url.present? && global_instance_token.present?
  end

  def channel_evolution_go_configured?
    api_base_url.present? && instance_token.present?
  end

  # Global configuration from Admin settings
  def global_api_base_url
    @global_api_base_url ||= GlobalConfigService.load('EVOLUTION_GO_API_URL', '')
  end

  def global_instance_token
    @global_instance_token ||= GlobalConfigService.load('EVOLUTION_GO_INSTANCE_SECRET', '')
  end

  # Channel configuration (existing)
  def api_base_url
    @api_base_url ||= whatsapp_channel.provider_config['api_url']
  end

  def admin_token
    @admin_token ||= whatsapp_channel.provider_config['admin_token']
  end

  def instance_token
    @instance_token ||= whatsapp_channel.provider_config['instance_token']
  end
end
