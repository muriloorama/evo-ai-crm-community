class AddAdStatusToCampaignInvestments < ActiveRecord::Migration[7.1]
  # Meta `effective_status` of the ad itself (ACTIVE, PAUSED, ARCHIVED,
  # DELETED, DISAPPROVED, etc.). Kept nullable for manually-entered rows
  # that never passed through the Meta sync.
  def change
    add_column :campaign_investments, :ad_status, :string
    add_index :campaign_investments, :ad_status
  end
end
