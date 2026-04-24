# == Schema Information
#
# Table name: follow_up_executions
#
#  id              :uuid             not null, primary key
#  attempts_at     :jsonb            not null
#  cancel_reason   :string
#  next_attempt_at :datetime         not null
#  status          :string           default("pending"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :uuid             not null
#  conversation_id :uuid             not null
#  rule_id         :uuid             not null
#
# Indexes
#
#  idx_follow_up_executions_by_conv          (conversation_id,status)
#  idx_follow_up_executions_runnable         (status,next_attempt_at)
#  index_follow_up_executions_on_account_id  (account_id)
#  index_follow_up_executions_on_rule_id     (rule_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (conversation_id => conversations.id) ON DELETE => cascade
#  fk_rails_...  (rule_id => follow_up_rules.id) ON DELETE => cascade
#
class FollowUpExecution < ApplicationRecord
  include Accountable

  STATUSES        = %w[pending done cancelled].freeze
  CANCEL_REASONS  = %w[agent_replied lead_replied moved_stage rule_disabled manual].freeze

  belongs_to :rule, class_name: 'FollowUpRule'
  belongs_to :conversation

  validates :status, inclusion: { in: STATUSES }
  validates :cancel_reason, inclusion: { in: CANCEL_REASONS }, allow_nil: true

  scope :pending,  -> { where(status: 'pending') }
  scope :runnable, -> { pending.where('next_attempt_at <= ?', Time.current) }

  def attempts_count
    Array(attempts_at).length
  end

  def cancel!(reason)
    update!(status: 'cancelled', cancel_reason: reason) if status == 'pending'
  end

  def record_attempt!
    update!(attempts_at: Array(attempts_at) + [Time.current.iso8601])
  end
end
