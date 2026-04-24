class CreateCampaignInvestments < ActiveRecord::Migration[7.1]
  def change
    create_table :campaign_investments, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.uuid   :account_id, null: false
      t.string :campaign_key, null: false   # match key: campaign_id OR source_label when campaign_id missing
      t.string :campaign_name
      t.string :source_type                 # meta_ad | instagram_ad | organic | other
      t.decimal :amount, precision: 12, scale: 2, null: false, default: 0
      t.string :currency, default: 'BRL', null: false
      t.date   :period_start, null: false
      t.date   :period_end, null: false
      t.text   :notes

      t.timestamps
    end

    add_index :campaign_investments, [:account_id, :campaign_key, :period_start], unique: true,
              name: 'idx_unique_campaign_period'
    add_index :campaign_investments, :account_id
    add_index :campaign_investments, :period_start
  end
end
