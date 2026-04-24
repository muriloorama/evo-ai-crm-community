# frozen_string_literal: true

# == Schema Information
#
# Table name: account_api_keys
#
#  id            :uuid             not null, primary key
#  last4         :string           not null
#  last_used_at  :datetime
#  name          :string           not null
#  revoked_at    :datetime
#  token         :string           not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  account_id    :uuid             not null
#  created_by_id :uuid             not null
#
# Indexes
#
#  index_account_api_keys_on_account_id                 (account_id)
#  index_account_api_keys_on_account_id_and_revoked_at  (account_id,revoked_at)
#  index_account_api_keys_on_created_by_id              (created_by_id)
#  index_account_api_keys_on_token                      (token) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (created_by_id => users.id)
#
class AccountApiKey < ApplicationRecord
  belongs_to :created_by, class_name: 'User'

  validates :account_id, :name, :token, :last4, presence: true
  validates :token, uniqueness: true

  scope :active, -> { where(revoked_at: nil) }

  before_validation :generate_token, on: :create

  def active?
    revoked_at.nil?
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  private

  def generate_token
    return if token.present?

    self.token = "evo_#{SecureRandom.hex(24)}"
    self.last4 = token.last(4)
  end
end
