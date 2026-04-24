# == Schema Information
#
# Table name: campaign_investments
#
#  id               :uuid             not null, primary key
#  ad_body          :text
#  ad_creative_url  :text
#  ad_headline      :text
#  ad_permalink_url :text
#  ad_status        :string
#  amount           :decimal(12, 2)   default(0.0), not null
#  campaign_key     :string           not null
#  campaign_name    :string
#  clicks           :bigint           default(0), not null
#  currency         :string           default("BRL"), not null
#  impressions      :bigint           default(0), not null
#  notes            :text
#  period_end       :date             not null
#  period_start     :date             not null
#  reach            :bigint           default(0), not null
#  source_type      :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :uuid             not null
#
# Indexes
#
#  idx_unique_campaign_per_account             (account_id,campaign_key) UNIQUE
#  index_campaign_investments_on_account_id    (account_id)
#  index_campaign_investments_on_ad_status     (ad_status)
#  index_campaign_investments_on_period_start  (period_start)
#
class CampaignInvestment < ApplicationRecord
  validates :campaign_key, presence: true
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :period_start, :period_end, presence: true
  validate :period_end_after_start

  scope :covering, ->(date) { where('period_start <= ? AND period_end >= ?', date, date) }
  scope :overlapping, lambda { |range|
    where('period_start <= ? AND period_end >= ?', range.last, range.first)
  }

  private

  def period_end_after_start
    return unless period_start && period_end
    errors.add(:period_end, 'must be on or after period_start') if period_end < period_start
  end
end
