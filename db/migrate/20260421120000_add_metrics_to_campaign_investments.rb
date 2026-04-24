class AddMetricsToCampaignInvestments < ActiveRecord::Migration[7.1]
  def up
    add_column :campaign_investments, :impressions, :bigint, default: 0, null: false
    add_column :campaign_investments, :reach,       :bigint, default: 0, null: false
    add_column :campaign_investments, :clicks,      :bigint, default: 0, null: false

    # The old unique index (account_id, campaign_key, period_start) created a new
    # row every time the sync ran with a shifted lookback window. Replace it with
    # (account_id, campaign_key) so the sync idempotently updates a single row
    # per campaign with the latest accumulated totals.
    remove_index :campaign_investments, name: 'idx_unique_campaign_period', if_exists: true
    add_index :campaign_investments, [:account_id, :campaign_key],
              unique: true, name: 'idx_unique_campaign_per_account'
  end

  def down
    remove_index :campaign_investments, name: 'idx_unique_campaign_per_account', if_exists: true
    add_index :campaign_investments, [:account_id, :campaign_key, :period_start],
              unique: true, name: 'idx_unique_campaign_period'
    remove_column :campaign_investments, :clicks
    remove_column :campaign_investments, :reach
    remove_column :campaign_investments, :impressions
  end
end
