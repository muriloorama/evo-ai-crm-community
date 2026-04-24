class CreateValidationCheckItems < ActiveRecord::Migration[7.1]
  def change
    create_table :validation_check_items, id: :uuid do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid
      t.references :checked_by, null: false, foreign_key: { to_table: :users }, type: :uuid
      # Stable string id (from the frontend checklist definition) — lets us
      # reshuffle/rename items in the UI without breaking existing marks.
      t.string :item_key, null: false
      t.timestamps

      t.index [:account_id, :item_key], unique: true, name: 'idx_validation_check_account_item'
    end
  end
end
