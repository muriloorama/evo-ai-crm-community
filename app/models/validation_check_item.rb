# frozen_string_literal: true

# == Schema Information
#
# Table name: validation_check_items
#
#  id            :uuid             not null, primary key
#  item_key      :string           not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  account_id    :uuid             not null
#  checked_by_id :uuid             not null
#
# Indexes
#
#  idx_validation_check_account_item              (account_id,item_key) UNIQUE
#  index_validation_check_items_on_account_id     (account_id)
#  index_validation_check_items_on_checked_by_id  (checked_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (checked_by_id => users.id)
#
class ValidationCheckItem < ApplicationRecord
  # `account_id` is a plain column — Account lives in evo-auth, not as a
  # local ActiveRecord model (same pattern as Conversation / Contact).
  belongs_to :checked_by, class_name: 'User'

  validates :account_id, presence: true
  validates :item_key, presence: true, uniqueness: { scope: :account_id }
end
