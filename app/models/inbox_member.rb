# == Schema Information
#
# Table name: inbox_members
#
#  id         :uuid             not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  account_id :uuid             not null
#  inbox_id   :uuid             not null
#  user_id    :uuid             not null
#
# Indexes
#
#  index_inbox_members_on_account_id            (account_id)
#  index_inbox_members_on_inbox_id              (inbox_id)
#  index_inbox_members_on_inbox_id_and_user_id  (inbox_id,user_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#
class InboxMember < ApplicationRecord
  validates :inbox_id, presence: true
  validates :user_id, presence: true
  validates :user_id, uniqueness: { scope: :inbox_id }

  belongs_to :user
  belongs_to :inbox

  after_create :add_agent_to_round_robin
  after_destroy :remove_agent_from_round_robin

  private

  def add_agent_to_round_robin
    ::AutoAssignment::InboxRoundRobinService.new(inbox: inbox).add_agent_to_queue(user_id)
  end

  def remove_agent_from_round_robin
    ::AutoAssignment::InboxRoundRobinService.new(inbox: inbox).remove_agent_from_queue(user_id) if inbox.present?
  end
end

