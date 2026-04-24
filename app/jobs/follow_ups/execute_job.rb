## Runs a single follow-up attempt: revalidates preconditions, crafts the
# message (template / AI), ships it via the conversation's inbox, and
# either schedules the next attempt or runs the terminal action.
#
# Preconditions are re-checked here (not only in the listener) because
# the execution could have been scheduled hours ago — the lead may have
# already replied or the pipeline item may have moved since.
class FollowUps::ExecuteJob < ApplicationJob
  queue_as :low

  def perform(execution_id)
    execution = FollowUpExecution.find_by(id: execution_id)
    return unless execution && execution.status == 'pending'

    rule         = execution.rule
    conversation = execution.conversation
    return cancel(execution, 'rule_disabled') unless rule&.enabled?
    return cancel(execution, 'moved_stage')   unless still_on_stage?(conversation, rule)
    return cancel(execution, 'lead_replied')  if lead_replied_since_last_attempt?(execution)
    return cancel(execution, 'agent_replied') if agent_replied_since_last_attempt?(execution)

    Accountable.with_account(execution.account_id) do
      dispatch_follow_up(execution, rule, conversation)
    end
  rescue StandardError => e
    Rails.logger.error "[FollowUps::ExecuteJob] #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    raise
  end

  private

  def dispatch_follow_up(execution, rule, conversation)
    result = FollowUps::AiMessageService.new(rule: rule, conversation: conversation).generate
    return cancel(execution, 'manual') if result.blank?

    # When the AI service delegates to an agent_bot, the bot's response
    # creates the outgoing message via ResponseProcessor — we only record
    # the attempt locally. For template/fallback paths, we send the text.
    send_outgoing_message(conversation, result) unless result == FollowUps::AiMessageService::ASYNC_RESULT
    execution.record_attempt!

    if execution.attempts_count >= rule.max_attempts
      handle_max_attempts(execution, rule, conversation)
    else
      schedule_next(execution, rule)
    end
  end

  def send_outgoing_message(conversation, text)
    conversation.messages.create!(
      content:      text,
      message_type: :outgoing,
      inbox_id:     conversation.inbox_id,
      account_id:   conversation.account_id,
      sender:       automation_sender(conversation),
      content_attributes: { follow_up: true }
    )
  end

  # The follow-up is a system-triggered message. Best effort: attribute it
  # to the conversation's assignee if present; otherwise leave it nil so
  # downstream dispatchers treat it as system-origin.
  def automation_sender(conversation)
    conversation.assignee || conversation.inbox.members.first
  end

  def schedule_next(execution, rule)
    next_index = execution.attempts_count
    delay      = Array(rule.intervals)[next_index]
    return cancel(execution, 'manual') unless delay.is_a?(Integer) && delay.positive?

    execution.update!(next_attempt_at: Time.current + delay.seconds)
  end

  def handle_max_attempts(execution, rule, conversation)
    execution.update!(status: 'done')

    return unless rule.on_max_attempts_action == 'move_to_stage' && rule.on_max_target_stage_id

    pipeline_item = conversation.pipeline_items.find_by(pipeline_stage_id: rule.pipeline_stage_id)
    pipeline_item&.update(pipeline_stage_id: rule.on_max_target_stage_id)
  rescue StandardError => e
    Rails.logger.warn "[FollowUps::ExecuteJob] move_to_stage failed: #{e.message}"
  end

  def still_on_stage?(conversation, rule)
    conversation.pipeline_items.exists?(pipeline_stage_id: rule.pipeline_stage_id)
  end

  def lead_replied_since_last_attempt?(execution)
    since = last_attempt_time(execution) || execution.created_at
    execution.conversation.messages.incoming.where('created_at > ?', since).exists?
  end

  def agent_replied_since_last_attempt?(execution)
    since = last_attempt_time(execution) || execution.created_at
    execution.conversation.messages.outgoing
             .where('created_at > ?', since)
             .where(sender_type: 'User')
             .exists?
  end

  def last_attempt_time(execution)
    stamp = Array(execution.attempts_at).last
    return nil if stamp.blank?

    Time.zone.parse(stamp.to_s)
  rescue ArgumentError
    nil
  end

  def cancel(execution, reason)
    execution.cancel!(reason)
  end
end
