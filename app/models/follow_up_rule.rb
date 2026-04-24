# == Schema Information
#
# Table name: follow_up_rules
#
#  id                     :uuid             not null, primary key
#  enabled                :boolean          default(TRUE), not null
#  extra_instructions     :text
#  intervals              :jsonb            not null
#  message_source         :string           default("inbox_agent"), not null
#  name                   :string           not null
#  on_max_attempts_action :string           default("noop"), not null
#  template_text          :text
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :uuid             not null
#  custom_agent_bot_id    :uuid
#  on_max_target_stage_id :uuid
#  pipeline_stage_id      :uuid             not null
#
# Indexes
#
#  idx_follow_up_rules_trigger          (account_id,pipeline_stage_id,enabled)
#  index_follow_up_rules_on_account_id  (account_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (custom_agent_bot_id => agent_bots.id) ON DELETE => nullify
#  fk_rails_...  (on_max_target_stage_id => pipeline_stages.id) ON DELETE => nullify
#  fk_rails_...  (pipeline_stage_id => pipeline_stages.id) ON DELETE => cascade
#
class FollowUpRule < ApplicationRecord
  include Accountable

  MESSAGE_SOURCES = %w[inbox_agent custom_agent template].freeze
  MAX_ATTEMPTS_ACTIONS = %w[noop move_to_stage].freeze

  belongs_to :pipeline_stage
  belongs_to :on_max_target_stage, class_name: 'PipelineStage', optional: true
  belongs_to :custom_agent_bot, class_name: 'AgentBot', optional: true
  has_many   :executions, class_name: 'FollowUpExecution', foreign_key: :rule_id, dependent: :destroy

  validates :name, presence: true, length: { maximum: 120 }
  validates :intervals, presence: true
  validates :message_source, inclusion: { in: MESSAGE_SOURCES }
  validates :on_max_attempts_action, inclusion: { in: MAX_ATTEMPTS_ACTIONS }

  validate :intervals_must_be_positive_integers
  validate :custom_agent_required_when_source_custom
  validate :template_required_when_source_template
  validate :target_stage_required_when_action_move

  scope :enabled, -> { where(enabled: true) }

  def max_attempts
    Array(intervals).length
  end

  private

  def intervals_must_be_positive_integers
    arr = Array(intervals)
    return errors.add(:intervals, 'cannot be empty')      if arr.empty?
    return errors.add(:intervals, 'too many attempts')    if arr.length > 10

    bad = arr.reject { |i| i.is_a?(Integer) && i.positive? }
    errors.add(:intervals, 'must be positive integers (seconds)') if bad.any?
  end

  def custom_agent_required_when_source_custom
    return unless message_source == 'custom_agent'
    errors.add(:custom_agent_bot_id, 'is required when message_source is custom_agent') if custom_agent_bot_id.blank?
  end

  def template_required_when_source_template
    return unless message_source == 'template'
    errors.add(:template_text, 'is required when message_source is template') if template_text.blank?
  end

  def target_stage_required_when_action_move
    return unless on_max_attempts_action == 'move_to_stage'
    errors.add(:on_max_target_stage_id, 'is required when on_max_attempts_action is move_to_stage') if on_max_target_stage_id.blank?
  end
end
