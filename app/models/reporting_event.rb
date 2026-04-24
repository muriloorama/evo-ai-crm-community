# == Schema Information
#
# Table name: reporting_events
#
#  id                      :uuid             not null, primary key
#  event_end_time          :datetime
#  event_start_time        :datetime
#  name                    :string
#  value                   :float
#  value_in_business_hours :float
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  account_id              :uuid             not null
#  conversation_id         :uuid
#  inbox_id                :uuid
#  user_id                 :uuid
#
# Indexes
#
#  index_reporting_events_on_account_id       (account_id)
#  index_reporting_events_on_conversation_id  (conversation_id)
#  index_reporting_events_on_created_at       (created_at)
#  index_reporting_events_on_inbox_id         (inbox_id)
#  index_reporting_events_on_name             (name)
#  index_reporting_events_on_user_id          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#
class ReportingEvent < ApplicationRecord
  validates :name, presence: true
  validates :value, presence: true

  belongs_to :user, optional: true
  belongs_to :inbox, optional: true
  belongs_to :conversation, optional: true
end
