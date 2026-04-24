# frozen_string_literal: true

module Webhooks
  class TelegramEventsJob < ApplicationJob
    queue_as :default

    def perform(params = {})
    Rails.logger.info "=== TELEGRAM WEBHOOK DEBUG ==="
    Rails.logger.info "Params received: #{params.inspect}"
    Rails.logger.info "Bot token: #{params[:bot_token]}"
    Rails.logger.info "Has telegram key? #{params[:telegram].present?}"
    Rails.logger.info "All keys: #{params.keys.inspect}"

    return unless params[:bot_token]

    channel = Channel::Telegram.find_by(bot_token: params[:bot_token])
    Rails.logger.info "Channel found: #{channel.inspect}"

    if channel_is_inactive?(channel)
      log_inactive_channel(channel, params)
      return
    end

    Accountable.with_account(channel.account_id) do
      process_event_params(channel, params)
    end
  end

  private

  def channel_is_inactive?(channel)
    return true if channel.blank?

    false
  end

  def log_inactive_channel(channel, params)
    message = if channel&.id
                "Channel #{channel.id} is inactive"
              else
                "Channel not found for bot_token: #{params[:bot_token]}"
              end
    Rails.logger.warn("Telegram event discarded: #{message}")
  end

  def process_event_params(channel, params)
    Rails.logger.info "Processing Telegram event for channel: #{channel.inbox.name}"

    unless params[:telegram]
      Rails.logger.warn "No 'telegram' key in params. Keys present: #{params.keys.inspect}"
      return
    end

    Rails.logger.info "Telegram data: #{params[:telegram].inspect}"

    if params.dig(:telegram, :edited_message).present?
      Rails.logger.info "Processing edited message"
      Telegram::UpdateMessageService.new(inbox: channel.inbox, params: params['telegram'].with_indifferent_access).perform
    else
      Rails.logger.info "Processing new message"
      Telegram::IncomingMessageService.new(inbox: channel.inbox, params: params['telegram'].with_indifferent_access).perform
    end

    Rails.logger.info "=== TELEGRAM WEBHOOK PROCESSED ==="
  end
  end
end
