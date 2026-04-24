class CreateAccountApiKeys < ActiveRecord::Migration[7.1]
  def change
    create_table :account_api_keys, id: :uuid do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid
      t.references :created_by, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.string :name, null: false
      # Store the raw token — community build, long enough (48 chars of
      # SecureRandom.hex(24)) to be effectively unguessable. last4 kept for
      # display since we don't show the raw token again after create.
      t.string :token, null: false
      t.string :last4, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps

      t.index :token, unique: true
      t.index [:account_id, :revoked_at]
    end
  end
end
