# frozen_string_literal: true

# == Schema Information
#
# Table name: broadcast_campaigns
#
#  id                    :uuid             not null, primary key
#  error_message         :text
#  failed_count          :integer          default(0)
#  finished_at           :datetime
#  name                  :string           not null
#  rate_limit_per_minute :integer          default(60)
#  scheduled_at          :datetime
#  sent_count            :integer          default(0)
#  started_at            :datetime
#  status                :integer          default("draft"), not null
#  template_language     :string
#  template_name         :string
#  template_params       :jsonb
#  total_recipients      :integer          default(0)
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :uuid             not null
#  created_by_id         :uuid             not null
#  inbox_id              :uuid             not null
#
# Indexes
#
#  index_broadcast_campaigns_on_account_id               (account_id)
#  index_broadcast_campaigns_on_account_id_and_status    (account_id,status)
#  index_broadcast_campaigns_on_created_by_id            (created_by_id)
#  index_broadcast_campaigns_on_inbox_id                 (inbox_id)
#  index_broadcast_campaigns_on_status_and_scheduled_at  (status,scheduled_at)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (created_by_id => users.id)
#  fk_rails_...  (inbox_id => inboxes.id)
#
class BroadcastCampaign < ApplicationRecord
  # account_id is a plain column — Account isn't a local AR model here.
  belongs_to :inbox
  belongs_to :created_by, class_name: 'User'

  has_many :broadcast_recipients, dependent: :destroy

  enum status: { draft: 0, queued: 1, running: 2, completed: 3, cancelled: 4, failed: 5 }

  validates :account_id, presence: true
  validates :name, presence: true
  validates :template_name, presence: true, if: :ready_to_send?
  validates :rate_limit_per_minute, numericality: { greater_than: 0, less_than_or_equal_to: 600 }

  def progress_percent
    return 0 if total_recipients.to_i.zero?

    ((sent_count.to_i + failed_count.to_i) * 100.0 / total_recipients).round(2)
  end

  def ready_to_send?
    queued? || running?
  end
end
