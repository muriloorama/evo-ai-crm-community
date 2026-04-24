# frozen_string_literal: true

# Decides whether a bot action (AI reply / inactivity message) is allowed
# to run right now, based on a weekly schedule stored on the AgentBot's
# `bot_config` JSONB column.
#
# Schedule shape:
#   {
#     "enabled": true,
#     "timezone": "America/Sao_Paulo",
#     "schedule": {
#       "monday":    { "start": "09:00", "end": "18:00" },
#       "tuesday":   { "start": "09:00", "end": "18:00" },
#       ...
#       "saturday":  null,    # closed
#       "sunday":    null     # closed
#     }
#   }
#
# If `enabled` is false/missing, the check always returns true (no gate).
# Invalid entries (missing keys, malformed times) default to "allowed"
# rather than silently blocking automations.
class AgentBots::ScheduleChecker
  DAY_KEYS = %w[sunday monday tuesday wednesday thursday friday saturday].freeze

  def self.within_window?(agent_bot, config_key, now: Time.current)
    new(agent_bot, config_key, now: now).within_window?
  end

  def initialize(agent_bot, config_key, now: Time.current)
    @agent_bot = agent_bot
    @config_key = config_key.to_s
    @now = now
  end

  def within_window?
    return true if config.blank?
    return true unless config['enabled']

    window = day_window
    return true if window.blank?
    return false if window == :closed

    current_minutes = local_now.hour * 60 + local_now.min
    current_minutes >= window[:start] && current_minutes < window[:end]
  rescue StandardError => e
    Rails.logger.warn "AgentBots::ScheduleChecker failed for bot #{@agent_bot&.id}: #{e.message}"
    true
  end

  private

  def config
    @config ||= @agent_bot&.bot_config&.dig(@config_key) || {}
  end

  def timezone
    config['timezone'].presence || 'America/Sao_Paulo'
  end

  def local_now
    @local_now ||= @now.in_time_zone(timezone)
  end

  def day_window
    day_key = DAY_KEYS[local_now.wday]
    day_config = config.dig('schedule', day_key)

    # Explicit null means closed for the day.
    return :closed if day_config.nil? && config.dig('schedule')&.key?(day_key)
    return nil if day_config.blank?

    {
      start: parse_hhmm(day_config['start']) || 0,
      end: parse_hhmm(day_config['end']) || 24 * 60
    }
  end

  def parse_hhmm(value)
    return nil if value.blank?

    hours, minutes = value.to_s.split(':').map(&:to_i)
    return nil unless hours.between?(0, 24) && minutes.between?(0, 59)

    hours * 60 + minutes
  end
end
