## Produces a single follow-up attempt.
#
# Dispatch path depends on `rule.message_source`:
#
#   - `template`      → renders static text (with {{name}} interpolation) and
#                       returns it; the caller (ExecuteJob) creates the
#                       outgoing message itself.
#   - `inbox_agent`   → fires the same AgentBots::HttpRequestService pipeline
#                       used by inactivity actions, with `event:
#                       'inactivity_action'` so the processor knows to reply
#                       inline. The bot's response goes through ResponseProcessor
#                       and becomes an outgoing message automatically. Returns
#                       `:async` so the caller skips its own send.
#   - `custom_agent`  → same as inbox_agent but using the rule's bot.
#
# When the agent dispatch fails (no agent configured, blank outgoing_url,
# HTTP error) we fall back to a neutral re-engagement line so the attempt
# doesn't silently drop.
class FollowUps::AiMessageService
  DEFAULT_FALLBACK = 'Oi! Notei que você ainda não retornou. Posso ajudar em algo?'
  ASYNC_RESULT     = :async

  attr_reader :rule, :conversation

  def initialize(rule:, conversation:)
    @rule         = rule
    @conversation = conversation
  end

  def generate
    case rule.message_source
    when 'template'     then render_template
    when 'inbox_agent'  then dispatch_via_agent(inbox_agent)
    when 'custom_agent' then dispatch_via_agent(rule.custom_agent_bot)
    else DEFAULT_FALLBACK
    end
  rescue StandardError => e
    Rails.logger.warn "[FollowUps::AiMessageService] generate failed: #{e.class} - #{e.message}"
    DEFAULT_FALLBACK
  end

  private

  def render_template
    text = rule.template_text.to_s
    variables.each { |key, value| text = text.gsub("{{#{key}}}", value.to_s) }
    text.presence || DEFAULT_FALLBACK
  end

  def variables
    contact = conversation.contact
    {
      'name'       => contact&.name.to_s.split.first.presence || 'tudo bem',
      'full_name'  => contact&.name.to_s,
      'email'      => contact&.email.to_s,
      'phone'      => contact&.phone_number.to_s,
      'inbox'      => conversation.inbox&.name.to_s,
      'attempt'    => (attempts_so_far + 1).to_s
    }
  end

  def attempts_so_far
    execution = conversation.follow_up_executions.order(created_at: :desc).first
    execution ? Array(execution.attempts_at).length : 0
  end

  def inbox_agent
    conversation.inbox&.agent_bot
  end

  # Fires the agent's outgoing webhook with an `inactivity_action` event —
  # the same channel used by AgentBots::InactivityActionsService. The bot
  # generates the re-engagement text and, when the response comes back,
  # AgentBots::ResponseProcessor creates the outgoing message inside the
  # conversation. Returning :async tells ExecuteJob to skip its own send.
  def dispatch_via_agent(agent_bot)
    return DEFAULT_FALLBACK if agent_bot.blank? || agent_bot.outgoing_url.blank?

    payload = build_agent_payload(agent_bot)
    AgentBots::HttpRequestService.new(agent_bot, payload).perform
    Rails.logger.info "[FollowUps] dispatched follow-up to agent #{agent_bot.name} (conv=#{conversation.id})"
    ASYNC_RESULT
  rescue StandardError => e
    Rails.logger.error "[FollowUps] agent dispatch failed for #{agent_bot&.name}: #{e.class} - #{e.message}"
    DEFAULT_FALLBACK
  end

  def build_agent_payload(agent_bot)
    extras = rule.extra_instructions.to_s.strip
    extras_block = extras.present? ? " Additional instructions: #{extras}" : ''

    prompt = "<system_message>[SYSTEM - FOLLOW-UP] The lead has been silent on the current pipeline " \
             "stage. Generate a short, natural re-engagement message in the conversation's language. " \
             "Attempt #{attempts_so_far + 1} of #{rule.max_attempts}.#{extras_block} " \
             '<important>Reply ONLY with the message text for the customer. Do NOT use any tools. ' \
             'Do NOT add meta-commentary. Just write the re-engagement message directly.</important></system_message>'

    {
      event: 'inactivity_action',
      id: SecureRandom.uuid,
      message_type: 'incoming',
      content: prompt,
      conversation: conversation.webhook_data.merge(id: conversation.id),
      conversation_id: conversation.id,
      inbox: conversation.inbox.webhook_data,
      inbox_id: conversation.inbox_id,
      sender: conversation.contact.webhook_data,
      contact_id: conversation.contact_id,
      created_at: Time.current.to_i,
      follow_up_metadata: {
        rule_id: rule.id,
        attempt_number: attempts_so_far + 1,
        max_attempts: rule.max_attempts,
        is_system_prompt: true
      }
    }
  end
end
