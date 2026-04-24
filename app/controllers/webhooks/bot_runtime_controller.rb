# frozen_string_literal: true

class Webhooks::BotRuntimeController < ActionController::API
  before_action :validate_secret

  def postback
    conversation = Conversation.find_by(display_id: params[:conversation_display_id])
    unless conversation
      render json: { error: 'Conversation not found' }, status: :not_found
      return
    end

    agent_bot = find_active_agent_bot(conversation)
    unless agent_bot
      render json: { error: 'No active agent bot for this conversation' }, status: :not_found
      return
    end

    content = params[:content]
    if content.blank?
      render json: { error: 'Content is required' }, status: :bad_request
      return
    end

    processed = AgentBots::TagProcessor.new(agent_bot).process(content)

    # Check eligibility once up front. If the conversation is no longer eligible
    # (human took over, status flipped, labels changed), drop the whole payload —
    # attachments included. Silently dropping just the text while still sending
    # the PDF would leave the lead with an attachment and no context.
    message = AgentBots::MessageCreator.new(agent_bot).create_bot_reply(processed[:clean_content], conversation) if processed[:clean_content].present?

    if processed[:clean_content].present? && message.nil?
      Rails.logger.warn "[BotRuntime::Postback] Bot reply blocked by eligibility check — skipping attachments conversation=#{conversation.display_id}"
      render json: { error: 'Conversation not eligible for bot reply' }, status: :unprocessable_entity
      return
    end

    processed[:attachments].each { |att| send_attachment(conversation, agent_bot, att) }

    Rails.logger.info "[BotRuntime::Postback] Postback processed: message=#{message&.id || 'none'} conversation=#{conversation.display_id} attachments=#{processed[:attachments].size}"
    render json: { status: 'sent' }, status: :ok
  end

  private

  def send_attachment(conversation, agent_bot, attachment)
    Rails.logger.info "[BotRuntime::Postback] Sending tag attachment tag=#{attachment.tag} url=#{attachment.url}"

    Accountable.with_account(conversation.account_id) do
      io = AgentBots::SafeAttachmentFetcher.call(attachment.url)

      ActiveRecord::Base.transaction do
        message = conversation.messages.create!(
          account_id:   conversation.account_id,
          inbox_id:     conversation.inbox_id,
          message_type: :outgoing,
          content:      nil,
          sender:       agent_bot,
          private:      false
        )

        message.attachments.create!(
          file_type: attachment.file_type,
          file:      { io: io, filename: attachment.filename, content_type: attachment.content_type }
        )
      end
    end
  rescue StandardError => e
    Rails.logger.error "[BotRuntime::Postback] Attachment send failed tag=#{attachment.tag}: #{e.class} #{e.message}"
  end

  def validate_secret
    expected_secret = BotRuntime::Config.secret

    # Skip validation when no secret is configured (development/testing)
    return if expected_secret.blank?

    provided_secret = request.headers['X-Bot-Runtime-Secret']
    return if provided_secret == expected_secret

    render json: { error: 'Unauthorized' }, status: :unauthorized
  end

  def find_active_agent_bot(conversation)
    inbox = conversation.inbox
    agent_bot_inbox = inbox.agent_bot_inbox
    return nil unless agent_bot_inbox&.active?

    agent_bot_inbox.agent_bot
  end
end
