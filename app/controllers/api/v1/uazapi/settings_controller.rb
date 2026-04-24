## Settings page for uazapi-backed WhatsApp channels.
#
# uazapi exposes a narrow surface for "instance behaviour" (presence, group
# muting, etc.) compared to the Evolution API. To keep parity with the
# Evolution settings UI, the flags are persisted in the channel's
# `provider_config['instance_settings']` hash. The flags that map to a real
# uazapi endpoint are also pushed live:
#   * `alwaysOnline` → POST /instance/presence (`available` | `unavailable`)
#
# Flags without a known uazapi endpoint are stored locally so the operator can
# still see what they configured. They become live as soon as we wire them
# to the corresponding uazapi calls.
class Api::V1::Uazapi::SettingsController < Api::V1::BaseController
  before_action :set_channel

  def show
    settings = (@channel.provider_config['instance_settings'] || {}).symbolize_keys
    # Flatten the response so the shared frontend (ConfigurationForm)
    # can read flags directly from `response.data.<flag>` — same shape as
    # the Evolution settings controller returns.
    render json: {
      success: true,
      data: default_settings.merge(settings).merge(
        instance_name: @channel.provider_config['instance_name']
      )
    }
  end

  def update
    incoming = settings_params.to_h
    merged   = (@channel.provider_config['instance_settings'] || {}).merge(incoming)

    @channel.provider_config = @channel.provider_config.merge('instance_settings' => merged)
    @channel.save!

    apply_live_flags(incoming)

    render json: {
      success: true,
      data: default_settings.merge(merged),
      message: 'Settings updated'
    }
  rescue ActiveRecord::RecordInvalid => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "Uazapi settings update error: #{e.message}"
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def set_channel
    instance_ref = params[:id].to_s.strip
    @channel = Channel::Whatsapp.joins(:inbox).where(provider: 'uazapi').find do |ch|
      config = ch.provider_config || {}
      [config['instance_name'], config['instance_token'], ch.inbox&.name].compact.include?(instance_ref)
    end

    return if @channel

    render json: { success: false, error: "Channel not found for instance: #{instance_ref}" }, status: :not_found
  end

  def settings_params
    params.require(:settings).permit(
      :rejectCall, :msgCall, :groupsIgnore, :alwaysOnline,
      :readMessages, :syncFullHistory, :readStatus
    )
  end

  def default_settings
    {
      rejectCall:      false,
      msgCall:         '',
      groupsIgnore:    false,
      alwaysOnline:    false,
      readMessages:    false,
      syncFullHistory: false,
      readStatus:      false
    }
  end

  # Push the flags that uazapi can act on live; leave the rest for local
  # persistence. Errors here do not abort the save — the operator's
  # preference is recorded either way and can be retried later.
  def apply_live_flags(incoming)
    return unless incoming.key?('alwaysOnline')

    target_presence = ActiveModel::Type::Boolean.new.cast(incoming['alwaysOnline']) ? 'available' : 'unavailable'
    @channel.update_presence(target_presence)
  rescue StandardError => e
    Rails.logger.warn "Uazapi: live flag push failed: #{e.message}"
  end
end
