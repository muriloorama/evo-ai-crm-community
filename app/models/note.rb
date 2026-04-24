# == Schema Information
#
# Table name: notes
#
#  id         :uuid             not null, primary key
#  content    :text             not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  account_id :uuid             not null
#  contact_id :uuid             not null
#  user_id    :uuid
#
# Indexes
#
#  index_notes_on_account_id  (account_id)
#  index_notes_on_contact_id  (contact_id)
#  index_notes_on_user_id     (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#
class Note < ApplicationRecord
  validates :content, presence: true
  validates :contact_id, presence: true

  belongs_to :contact
  belongs_to :user, optional: true

  scope :latest, -> { order(created_at: :desc) }
end
