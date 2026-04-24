## CRUD for follow-up rules. Scoped automatically to Current.account_id via
# the Accountable concern, so this controller does not need to add account
# checks itself.
class Api::V1::FollowUpRulesController < Api::V1::BaseController
  before_action :set_rule, only: %i[show update destroy]

  def index
    @rules = FollowUpRule.order(created_at: :desc)
    success_response(
      data: { follow_up_rules: @rules.map { |r| serialize(r) } },
      message: 'Follow-up rules retrieved'
    )
  end

  def show
    success_response(data: { follow_up_rule: serialize(@rule) }, message: 'Follow-up rule retrieved')
  end

  def create
    @rule = FollowUpRule.new(rule_params)
    if @rule.save
      success_response(data: { follow_up_rule: serialize(@rule) }, message: 'Follow-up rule created', status: :created)
    else
      render_unprocessable(@rule)
    end
  end

  def update
    if @rule.update(rule_params)
      success_response(data: { follow_up_rule: serialize(@rule) }, message: 'Follow-up rule updated')
    else
      render_unprocessable(@rule)
    end
  end

  def destroy
    @rule.destroy
    success_response(data: {}, message: 'Follow-up rule deleted')
  end

  private

  def set_rule
    @rule = FollowUpRule.find(params[:id])
  end

  def rule_params
    params.require(:follow_up_rule).permit(
      :name, :pipeline_stage_id, :message_source, :custom_agent_bot_id,
      :template_text, :extra_instructions, :on_max_attempts_action,
      :on_max_target_stage_id, :enabled,
      intervals: []
    )
  end

  def serialize(rule)
    {
      id:                      rule.id,
      name:                    rule.name,
      pipeline_stage_id:       rule.pipeline_stage_id,
      pipeline_stage_name:     rule.pipeline_stage&.name,
      intervals:               rule.intervals,
      message_source:          rule.message_source,
      custom_agent_bot_id:     rule.custom_agent_bot_id,
      custom_agent_bot_name:   rule.custom_agent_bot&.name,
      template_text:           rule.template_text,
      extra_instructions:      rule.extra_instructions,
      on_max_attempts_action:  rule.on_max_attempts_action,
      on_max_target_stage_id:  rule.on_max_target_stage_id,
      on_max_target_stage_name: rule.on_max_target_stage&.name,
      enabled:                 rule.enabled,
      executions_pending:      rule.executions.pending.count,
      created_at:              rule.created_at,
      updated_at:              rule.updated_at
    }
  end

  def render_unprocessable(record)
    error_response(
      code: ApiErrorCodes::VALIDATION_ERROR,
      message: 'Validation failed',
      details: record.errors.full_messages,
      status: :unprocessable_entity
    )
  rescue NameError
    render json: { success: false, error: { message: 'Validation failed', details: record.errors.full_messages } }, status: :unprocessable_entity
  end
end
