# == Schema Information
#
# Table name: webhooks
#
#  id            :uuid             not null, primary key
#  name          :string
#  subscriptions :jsonb
#  url           :string
#  webhook_type  :integer          default("account_type")
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  account_id    :uuid             not null
#  inbox_id      :uuid
#
# Indexes
#
#  index_webhooks_on_account_id  (account_id)
#  index_webhooks_on_url         (url) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#
class Webhook < ApplicationRecord
  belongs_to :inbox, optional: true

  validates :url, uniqueness: true, format: URI::DEFAULT_PARSER.make_regexp(%w[http https])
  validate :validate_webhook_subscriptions
  enum webhook_type: { account_type: 0, inbox_type: 1 }

  ALLOWED_WEBHOOK_EVENTS = %w[conversation_status_changed conversation_updated conversation_created contact_created contact_updated
                              message_created message_updated webwidget_triggered inbox_created inbox_updated
                              conversation_typing_on conversation_typing_off
                              pipeline_task.created pipeline_task.completed pipeline_task.overdue pipeline_task.updated pipeline_task.cancelled
                              pipeline_item.created pipeline_item.updated pipeline_item.completed pipeline_item.cancelled].freeze

  private

  def validate_webhook_subscriptions
    invalid_subscriptions = !subscriptions.instance_of?(Array) ||
                            subscriptions.blank? ||
                            (subscriptions.uniq - ALLOWED_WEBHOOK_EVENTS).length.positive?
    errors.add(:subscriptions, I18n.t('errors.webhook.invalid')) if invalid_subscriptions
  end
end

