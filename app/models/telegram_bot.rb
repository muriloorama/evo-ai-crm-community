# == Schema Information
#
# Table name: telegram_bots
#
#  id         :uuid             not null, primary key
#  auth_key   :string
#  name       :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  account_id :uuid             not null
#
# Indexes
#
#  index_telegram_bots_on_account_id  (account_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#
class TelegramBot < ApplicationRecord
  has_one :inbox, as: :channel, dependent: :destroy_async
  validates :auth_key, uniqueness: true
end
