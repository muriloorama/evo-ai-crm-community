class CreateMetaAdAccounts < ActiveRecord::Migration[7.1]
  def change
    create_table :meta_ad_accounts, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.uuid     :account_id, null: false
      t.string   :ad_account_id, null: false  # e.g. "act_1234567890"
      t.string   :ad_account_name
      t.string   :business_name
      t.text     :access_token, null: false
      t.datetime :token_expires_at
      t.datetime :last_sync_at
      t.string   :last_sync_status      # 'ok' | 'error'
      t.text     :last_sync_error
      t.integer  :last_sync_campaigns_count, default: 0
      t.string   :currency, default: 'BRL'
      t.boolean  :active, null: false, default: true

      t.timestamps
    end

    add_index :meta_ad_accounts, [:account_id, :ad_account_id], unique: true,
              name: 'idx_meta_ad_accounts_unique'
    add_index :meta_ad_accounts, :account_id
  end
end
