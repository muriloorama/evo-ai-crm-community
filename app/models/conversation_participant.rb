# == Schema Information
#
# Table name: conversation_participants
#
#  id              :uuid             not null, primary key
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :uuid             not null
#  conversation_id :uuid             not null
#  user_id         :uuid             not null
#
# Indexes
#
#  index_conversation_participants_on_account_id                   (account_id)
#  index_conversation_participants_on_conversation_id              (conversation_id)
#  index_conversation_participants_on_user_id                      (user_id)
#  index_conversation_participants_on_user_id_and_conversation_id  (user_id,conversation_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#
class ConversationParticipant < ApplicationRecord
  validates :conversation_id, presence: true
  validates :user_id, presence: true
  validates :user_id, uniqueness: { scope: [:conversation_id] }
  validate :ensure_inbox_access

  belongs_to :conversation
  belongs_to :user

  private

  def ensure_inbox_access
    errors.add(:user, 'must have inbox access') if conversation && conversation.inbox.assignable_agents.exclude?(user)
  end
end
