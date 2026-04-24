# frozen_string_literal: true

module BotRuntime
  class SendEventJob < ApplicationJob
    queue_as :bot_runtime
    retry_on StandardError, wait: :polynomially_longer, attempts: 3

    discard_on BotRuntime::CircuitBreaker::CircuitOpenError do |_job, error|
      Rails.logger.warn "[BotRuntime::SendEventJob] Discarded: #{error.message}"
    end

    MEDIA_WAIT_TIMEOUT = 15  # seconds
    MEDIA_WAIT_POLL    = 1   # second

    def perform(event)
      Rails.logger.info "[BotRuntime::SendEventJob] Sending event: " \
                        "conversation_id=#{event[:conversation_id]} agent_bot_id=#{event[:agent_bot_id]}"

      message_id = event[:message_id] || event['message_id']
      if message_id.present?
        message = Accountable.as_super_admin { Message.find_by(id: message_id) }
        if message
          # Hold the dispatch briefly while Whisper (audio) / Vision (image)
          # finish their async jobs, so the LLM sees the transcription/
          # description in the payload instead of a bare marker.
          wait_for_media_enrichment(message)

          refreshed = BotRuntime::MessageContentBuilder.build(message)
          if refreshed.present?
            event = event.merge(message_content: refreshed)
            Rails.logger.info "[BotRuntime::SendEventJob] Refreshed content (len=#{refreshed.length}) for message=#{message_id}"
          end
        end
      end

      BotRuntime::Client.new.send_event(event)

      Rails.logger.info "[BotRuntime::SendEventJob] Event sent successfully: " \
                        "conversation_id=#{event[:conversation_id]}"
    end

    private

    def wait_for_media_enrichment(message)
      media = message.attachments.select { |a| %w[audio image].include?(a.file_type.to_s) }
      return if media.empty?

      deadline = Time.current + MEDIA_WAIT_TIMEOUT
      loop do
        missing = media.any? do |att|
          att.reload
          key = att.file_type.to_s == 'audio' ? 'transcribed_text' : 'image_description'
          att.meta&.[](key).to_s.strip.empty?
        end
        break unless missing
        break if Time.current >= deadline

        sleep MEDIA_WAIT_POLL
      end
    end
  end
end
