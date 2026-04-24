class AgentBots::ResponseProcessor
  ATTACHMENT_TAG = /\[\[ENVIAR_BROCHURA\]\]/.freeze

  def initialize(agent_bot, payload)
    @agent_bot = agent_bot
    @payload = payload
  end

  def process(response)
    return unless response

    status_code = response.code.to_i
    Rails.logger.info "[AgentBot HTTP] Response Status: #{response.code} #{response.message}"

    if success_response?(status_code)
      handle_success_response(response)
    else
      handle_error_response(response)
    end
  end

  private

  def success_response?(status_code)
    status_code >= 200 && status_code < 300
  end

  def handle_success_response(response)
    Rails.logger.info "[AgentBot HTTP] Success: #{response.code}"

    begin
      parsed_response = JSON.parse(response.body)
      Rails.logger.info "[AgentBot HTTP] Parsed Response: #{parsed_response}"
      process_bot_response(parsed_response)
    rescue JSON::ParserError => e
      Rails.logger.error "[AgentBot HTTP] JSON parsing failed: #{e.message}"
    end
  end

  def handle_error_response(response)
    Rails.logger.error "[AgentBot HTTP] Error Response: #{response.code} - #{response.body}"
  end

  def process_bot_response(parsed_response)
    artifacts = extract_artifacts(parsed_response)
    return unless artifacts

    text_content = extract_text_from_artifacts(artifacts)
    return unless text_content

    conversation = AgentBots::ConversationFinder.new(@agent_bot, @payload).find_conversation
    return unless conversation

    # The HTTP request that triggered this processor runs outside any user
    # request context (SendiKiq job), so `Current.account_id` is nil and the
    # Accountable before_validation callback can't auto-fill the message's
    # account_id. Wrap bot-reply creation with the conversation's account_id
    # so the NOT NULL constraint on messages.account_id is satisfied.
    Accountable.with_account(conversation.account_id) do
      attachment_url = @agent_bot.bot_config&.dig('pre_transfer_attachment_url')
      should_send_attachment = attachment_url.present? && text_content.match?(ATTACHMENT_TAG)
      text_content = text_content.gsub(ATTACHMENT_TAG, '').strip if should_send_attachment

      if @agent_bot.text_segmentation_enabled && ['evo_ai_provider', 'n8n_provider'].include?(@agent_bot.bot_provider)
        process_segmented_response(text_content, conversation)
      else
        final_content = build_message_with_signature(text_content)
        Rails.logger.info "[AgentBot HTTP] Bot Response Message: #{final_content}"

        message_creator = AgentBots::MessageCreator.new(@agent_bot)
        message = message_creator.create_bot_reply(final_content, conversation)

        unless message
          Rails.logger.info "[AgentBot HTTP] Message creation failed (conversation not eligible), attempting force create..."
          message = message_creator.create_bot_reply(final_content, conversation, force: true)
        end

        message
      end

      send_pre_transfer_attachment(conversation, attachment_url) if should_send_attachment
    end
  end

  def send_pre_transfer_attachment(conversation, url)
    Rails.logger.info "[AgentBot HTTP] Sending pre-transfer attachment from #{url}"

    user = conversation.assignee || conversation.account.users.first
    return unless user

    filename = url.split('?').first.split('/').last.presence || 'documento.pdf'
    io = AgentBots::SafeAttachmentFetcher.call(url)

    message = nil
    ActiveRecord::Base.transaction do
      message = conversation.messages.create!(
        account_id: conversation.account_id,
        inbox_id: conversation.inbox_id,
        message_type: :outgoing,
        content: nil,
        sender: @agent_bot,
        private: false
      )
      message.attachments.create!(
        file_type: :file,
        file: { io: io, filename: filename, content_type: 'application/pdf' }
      )
    end

    Rails.logger.info "[AgentBot HTTP] Pre-transfer attachment queued (message_id=#{message.id})"
  rescue StandardError => e
    Rails.logger.error "[AgentBot HTTP] Pre-transfer attachment failed: #{e.class} #{e.message}"
  end

  def extract_artifacts(parsed_response)
    artifacts = parsed_response.dig('result', 'artifacts')
    return unless artifacts&.any?

    artifacts
  end

  def extract_text_from_artifacts(artifacts)
    artifact = artifacts.first
    return unless artifact['parts']&.any?

    text_part = artifact['parts'].find { |p| p['type'] == 'text' }
    text_part&.dig('text')
  end

  def process_segmented_response(text_content, conversation)
    # Create segmentation service with bot's configuration
    segmentation_service = AgentBots::TextSegmentationService.new(
      @agent_bot.text_segmentation_limit || 300,
      @agent_bot.text_segmentation_min_size || 50
    )

    # Segment the text
    segments = segmentation_service.segment_text(text_content)

    Rails.logger.info "[AgentBot HTTP] Text segmented into #{segments.length} parts"
    segments.each_with_index do |segment, index|
      Rails.logger.info "[AgentBot HTTP] Segment #{index + 1}: #{segment[0..100]}#{'...' if segment.length > 100}"
    end

    # Create messages using the segmented message creator
    message_creator = AgentBots::SegmentedMessageCreator.new(@agent_bot)
    message_creator.create_messages(segments, conversation)
  end

  def build_message_with_signature(content)
    return content if @agent_bot.message_signature.blank?

    # Add signature at the top with two line breaks before the message
    "#{@agent_bot.message_signature}\n\n#{content}"
  end
end
