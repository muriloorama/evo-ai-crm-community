# frozen_string_literal: true

# InboxSerializer - Optimized serialization for Inbox resources
#
# Plain Ruby module for Oj direct serialization
#
# Usage:
#   InboxSerializer.serialize(@inbox, include_channel: true)
#
module InboxSerializer
  extend self

  # Serialize single Inbox with optimized field selection
  #
  # @param inbox [Inbox] Inbox to serialize
  # @param options [Hash] Serialization options
  # @option options [Boolean] :include_channel Include channel details
  # @option options [Boolean] :include_portal Include portal details
  # @option options [Boolean] :include_members Include team members
  #
  # @return [Hash] Serialized inbox ready for Oj
  #
  def serialize(inbox, include_channel: false, include_portal: false, include_members: false)
    # 🔒 SECURITY: hmac_token is excluded from as_json to prevent exposure in public APIs
    # It will be conditionally added later only for administrators
    result = inbox.as_json(
      only: [:id, :channel_id, :name, :display_name, :channel_type, :greeting_enabled,
             :greeting_message, :enable_email_collect, :csat_survey_enabled,
             :enable_auto_assignment, :working_hours_enabled, :out_of_office_message,
             :timezone, :allow_messages_after_resolved, :auto_assignment_config,
             :business_name, :portal_id,
             :sender_name_type, :additional_attributes, :csat_config,
             :lock_to_single_conversation, :default_conversation_status, :callback_webhook_url],
      methods: [:avatar_url]
    )

    # Include working_hours (weekly_schedule)
    result['working_hours'] = inbox.weekly_schedule if inbox.respond_to?(:weekly_schedule)

    # Timestamps
    result['created_at'] = inbox.created_at.to_i
    result['updated_at'] = inbox.updated_at.to_i

    # Include channel-specific fields
    if inbox.channel.present?
      # Provider (used by WhatsApp and other channels)
      result['provider'] = inbox.channel.provider if inbox.channel.respond_to?(:provider)

      # Phone number lives on the channel, not the inbox, but every screen
      # that lists inboxes (Canais page, sidebar, dropdowns) wants to show
      # it — expose it at the top level.
      #
      # Uazapi channels are created with a placeholder like
      # "+uazapi-mo4qnih53ra1c4" until the QR-code pairing completes. Once
      # the real phone owner is known (via webhook or /instance/status), we
      # cache it in provider_config['owner_phone_number'] and prefer it
      # here so the UI shows the actual connected number.
      raw_phone = inbox.channel.try(:phone_number)
      owner = inbox.channel.try(:provider_config)&.dig('owner_phone_number')
      result['phone_number'] = if raw_phone.to_s.start_with?('+uazapi-') && owner.present?
                                 owner
                               else
                                 raw_phone
                               end

      # WhatsApp-specific data required by channel settings screens
      if inbox.whatsapp?
        result['provider_config'] = inbox.channel.try(:provider_config)
        result['provider_connection'] = inbox.channel.try(:provider_connection_data)
      end

      # API Channel specific fields
      if inbox.api?
        result['hmac_mandatory'] = inbox.channel.hmac_mandatory
        result['webhook_url'] = inbox.channel.webhook_url
        result['inbox_identifier'] = inbox.channel.identifier
        result['additional_attributes'] = inbox.channel.additional_attributes
        result['hmac_token'] = inbox.channel.hmac_token if Current.user&.role == 'administrator'
      end

      # WebWidget specific fields
      if inbox.web_widget?
        result['website_url'] = inbox.channel.website_url
        result['widget_color'] = inbox.channel.widget_color
        result['welcome_title'] = inbox.channel.welcome_title
        result['welcome_tagline'] = inbox.channel.welcome_tagline
        result['web_widget_script'] = inbox.channel.web_widget_script
        result['website_token'] = inbox.channel.website_token
        result['selected_feature_flags'] = inbox.channel.selected_feature_flags
        result['reply_time'] = inbox.channel.reply_time
        result['locale'] = inbox.channel.locale
        result['pre_chat_form_enabled'] = inbox.channel.pre_chat_form_enabled
        result['pre_chat_form_options'] = inbox.channel.pre_chat_form_options
        result['continuity_via_email'] = inbox.channel.continuity_via_email
        result['hmac_mandatory'] = inbox.channel.hmac_mandatory
        result['hmac_token'] = inbox.channel.hmac_token if Current.user&.role == 'administrator'
      end

      # Include full channel if requested
      # 🔒 SECURITY: Exclude hmac_token from channel serialization to prevent exposure
      if include_channel
        channel_data = inbox.channel.as_json(except: [:created_at, :updated_at, :hmac_token])
        # Only include hmac_token if user is administrator
        if Current.user&.role == 'administrator' && inbox.channel.respond_to?(:hmac_token)
          channel_data['hmac_token'] = inbox.channel.hmac_token
        end
        result['channel'] = channel_data
      end
    end

    # Include portal
    if include_portal && inbox.portal.present?
      result['portal'] = {
        id: inbox.portal.id,
        name: inbox.portal.name,
        slug: inbox.portal.slug
      }
    end

    # Include members
    if include_members
      result['members'] = inbox.members.map do |member|
        UserSerializer.serialize(member)
      end
    end

    result
  end

  # Serialize collection of Inboxes
  #
  # @param inboxes [Array<Inbox>, ActiveRecord::Relation]
  # @param options [Hash] Same options as serialize method
  #
  # @return [Array<Hash>] Array of serialized inboxes
  #
  def serialize_collection(inboxes, **options)
    return [] unless inboxes

    inboxes.map { |inbox| serialize(inbox, **options) }
  end
end
