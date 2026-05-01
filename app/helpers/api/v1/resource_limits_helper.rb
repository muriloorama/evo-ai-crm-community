# frozen_string_literal: true

# Resource-limit / feature-flag enforcement for V1 API controllers.
#
# Wired into the central FeatureGate (lib/account_feature_gate.rb), which
# reads per-account overrides + falls back to platform defaults
# (config/account_defaults.yml). Methods short-circuit with a 422 / 403
# render when a cap is hit or a feature is off; otherwise they no-op so
# callers remain unchanged.
module Api::V1::ResourceLimitsHelper
  def validate_agent_bot_limit
    return unless Current.account

    unless AccountFeatureGate.allows?(Current.account, 'ai.enabled')
      return error_response(
        ApiErrorCodes::FORBIDDEN,
        'Atendimento por IA está desabilitado para este workspace.',
        status: :forbidden
      )
    end

    cap = AccountFeatureGate.limit(Current.account, 'ai.max_bots')
    return if cap.nil?
    return if AgentBot.count < cap

    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      "Workspace atingiu o limite de agentes de IA (#{cap}).",
      status: :unprocessable_entity
    )
  end

  def validate_pipeline_limit
    return unless Current.account
    return if AccountFeatureGate.allows?(Current.account, 'features.pipelines')

    error_response(
      ApiErrorCodes::FORBIDDEN,
      'Pipelines está desabilitado para este workspace.',
      status: :forbidden
    )
  end

  def validate_automation_limit
    return unless Current.account
    return if AccountFeatureGate.allows?(Current.account, 'features.automations')

    error_response(
      ApiErrorCodes::FORBIDDEN,
      'Automações está desabilitado para este workspace.',
      status: :forbidden
    )
  end

  def validate_team_limit
    # No team-count cap currently exposed in account defaults.
  end

  # Channel toggles map provider -> feature key under `channels.*`. The
  # helper is invoked from controllers that already know the channel type.
  def validate_channel_limit(channel_type)
    return unless Current.account
    feature_key = channel_feature_key(channel_type)
    return if feature_key.nil?
    return if AccountFeatureGate.allows?(Current.account, feature_key)

    error_response(
      ApiErrorCodes::FORBIDDEN,
      "Canal \"#{channel_type}\" está desabilitado para este workspace.",
      status: :forbidden
    )
  end

  def validate_custom_attribute_limit(_attribute_model)
    # No cap currently exposed in account defaults.
  end

  # Called from InboxesController#create. Reads the channel type/provider
  # from request params and gates both the global inbox cap AND the
  # per-channel toggle.
  def validate_channel_limit_for_creation
    return unless Current.account

    cap = AccountFeatureGate.limit(Current.account, 'limits.max_inboxes')
    if cap && Inbox.count >= cap
      return error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        "Workspace atingiu o limite de caixas de entrada (#{cap}).",
        status: :unprocessable_entity
      )
    end

    channel_node = params[:channel].is_a?(ActionController::Parameters) ||
                   params[:channel].is_a?(Hash) ? params[:channel] : nil
    return unless channel_node

    feature_key = channel_feature_key_from_params(channel_node)
    return if feature_key.nil?
    return if AccountFeatureGate.allows?(Current.account, feature_key)

    error_response(
      ApiErrorCodes::FORBIDDEN,
      'Este canal está desabilitado para este workspace.',
      status: :forbidden
    )
  end

  # Public so non-helper callers can reuse the mapping.
  def channel_feature_key(channel_type)
    case channel_type.to_s
    when 'Channel::Whatsapp', 'whatsapp', 'whatsapp_cloud'
      'channels.whatsapp_cloud'
    when 'Channel::Email', 'email'
      'channels.email'
    when 'Channel::Api', 'api'
      'channels.api'
    when 'Channel::FacebookPage', 'facebook'
      'channels.facebook'
    when 'Channel::Instagram', 'instagram'
      'channels.instagram'
    end
  end
  module_function :channel_feature_key

  private

  # Maps the inbox-create params shape to the right channel toggle key.
  def channel_feature_key_from_params(channel_node)
    type     = channel_node[:type] || channel_node['type']
    provider = channel_node[:provider] || channel_node['provider']

    return 'channels.email'    if type.to_s == 'email'
    return 'channels.api'      if type.to_s == 'api'
    return 'channels.facebook' if type.to_s == 'facebook' || channel_node[:type].to_s == 'Channel::FacebookPage'
    return 'channels.instagram' if type.to_s == 'instagram'

    if type.to_s == 'whatsapp'
      case provider.to_s
      when 'uazapi'                          then 'channels.whatsapp_uazapi'
      when 'evolution_api', 'evolution_go'   then 'channels.whatsapp_evolution'
      else                                       'channels.whatsapp_cloud'
      end
    end
  end

  def limit_is_unlimited?(limit_value)
    limit_value.nil?
  end
end
