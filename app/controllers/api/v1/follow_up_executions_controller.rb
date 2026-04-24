## Read-only view over executions in flight. Useful for the "in progress"
# tab of the follow-ups page so operators can see who is being followed up,
# at which attempt and when the next ping will fire.
class Api::V1::FollowUpExecutionsController < Api::V1::BaseController
  def index
    scope = FollowUpExecution.includes(:rule, conversation: :contact).order(next_attempt_at: :asc)
    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = scope.where(rule_id: params[:rule_id]) if params[:rule_id].present?

    @executions = scope.limit(200)

    success_response(
      data: { follow_up_executions: @executions.map { |e| serialize(e) } },
      message: 'Follow-up executions retrieved'
    )
  end

  private

  def serialize(execution)
    contact = execution.conversation&.contact
    {
      id:               execution.id,
      rule_id:          execution.rule_id,
      rule_name:        execution.rule&.name,
      conversation_id:  execution.conversation_id,
      contact_name:     contact&.name,
      contact_phone:    contact&.phone_number,
      status:           execution.status,
      cancel_reason:    execution.cancel_reason,
      attempts_count:   execution.attempts_count,
      max_attempts:     execution.rule&.max_attempts,
      next_attempt_at:  execution.next_attempt_at,
      attempts_at:      execution.attempts_at,
      created_at:       execution.created_at
    }
  end
end
