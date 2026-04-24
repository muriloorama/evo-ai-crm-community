# == Schema Information
#
# Table name: meta_ad_accounts
#
#  id                        :uuid             not null, primary key
#  access_token              :text             not null
#  active                    :boolean          default(TRUE), not null
#  ad_account_name           :string
#  business_name             :string
#  currency                  :string           default("BRL")
#  last_sync_at              :datetime
#  last_sync_campaigns_count :integer          default(0)
#  last_sync_error           :text
#  last_sync_status          :string
#  token_expires_at          :datetime
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  account_id                :uuid             not null
#  ad_account_id             :string           not null
#
# Indexes
#
#  idx_meta_ad_accounts_unique           (account_id,ad_account_id) UNIQUE
#  index_meta_ad_accounts_on_account_id  (account_id)
#
class MetaAdAccount < ApplicationRecord
  validates :ad_account_id, presence: true, format: { with: /\Aact_\d+\z/, message: 'must look like act_123456789' }
  validates :access_token, presence: true
  validates :ad_account_id, uniqueness: { scope: :account_id }

  scope :active, -> { where(active: true) }

  def token_expired?
    token_expires_at.present? && token_expires_at < Time.current
  end

  def token_expiring_soon?
    token_expires_at.present? && token_expires_at < 7.days.from_now
  end

  def token_days_until_expiry
    return nil if token_expires_at.blank?

    ((token_expires_at - Time.current) / 1.day).floor
  end
end
