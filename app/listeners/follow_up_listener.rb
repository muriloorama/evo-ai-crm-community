## Wires the follow-up system into the event bus.
#
# Three responsibilities:
#   * Create executions when a pipeline item lands on a stage with a rule.
#   * Cancel executions when the lead replies, the agent replies, or the
#     pipeline item moves away from the rule's stage.
#
# All work is light-weight — we never call AI or send messages from here.
# That lives in FollowUps::ExecuteJob, scheduled against next_attempt_at.
class FollowUpListener < BaseListener
  def pipeline_item_created(event)
    item = event.data[:pipeline_item]
    return unless item

    schedule_for_stage(item)
  end

  def pipeline_stage_updated(event)
    item     = event.data[:pipeline_item]
    changes  = event.data[:changed_attributes] || {}
    old_stage_id, new_stage_id = changes['pipeline_stage_id']
    return unless item && new_stage_id

    # Executions bound to the old stage are no longer valid.
    cancel_pending_for_conversation(item.conversation_id, 'moved_stage') if old_stage_id
    schedule_for_stage(item)
  end

  def message_created(event)
    message = extract_message_and_account(event)[0]
    return unless message&.conversation_id

    reason = cancel_reason_for(message)
    return unless reason

    cancel_pending_for_conversation(message.conversation_id, reason)
  end

  private

  def schedule_for_stage(item)
    return unless item.conversation_id && item.pipeline_stage_id

    rules = FollowUpRule.enabled.where(pipeline_stage_id: item.pipeline_stage_id)
    rules.find_each do |rule|
      interval = Array(rule.intervals).first
      next if interval.blank?

      # Avoid duplicate pending executions for the same (rule, conversation).
      FollowUpExecution.find_or_create_by!(
        rule_id:         rule.id,
        conversation_id: item.conversation_id,
        status:          'pending'
      ) do |exec|
        exec.next_attempt_at = Time.current + interval.to_i.seconds
      end
    end
  rescue StandardError => e
    Rails.logger.error "[FollowUpListener] schedule_for_stage failed: #{e.class} - #{e.message}"
  end

  def cancel_pending_for_conversation(conversation_id, reason)
    FollowUpExecution
      .pending
      .where(conversation_id: conversation_id)
      .find_each { |exec| exec.cancel!(reason) }
  rescue StandardError => e
    Rails.logger.error "[FollowUpListener] cancel_pending failed: #{e.class} - #{e.message}"
  end

  # A message cancels the follow-up when it's an actual conversation
  # response — either from the contact (incoming) or a human agent
  # (outgoing + sender is a User, not the bot itself).
  def cancel_reason_for(message)
    return 'lead_replied'  if message.incoming?
    return unless message.outgoing?

    # Only count as "agent replied" when a real person sent it — bot
    # messages, automations, etc. should not cancel the follow-up.
    sender = message.sender
    return 'agent_replied' if sender.is_a?(User)

    nil
  end
end
