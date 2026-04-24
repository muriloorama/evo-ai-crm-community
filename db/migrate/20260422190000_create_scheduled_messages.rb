class CreateScheduledMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :scheduled_messages, id: :uuid do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid
      t.references :conversation, null: false, foreign_key: true, type: :uuid
      t.references :inbox, null: false, foreign_key: true, type: :uuid
      t.references :created_by, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.text :content, default: ''
      t.datetime :scheduled_at, null: false
      t.integer :status, null: false, default: 0  # 0=pending, 1=sent, 2=cancelled, 3=failed
      t.datetime :sent_at
      t.string :error_message
      t.uuid :message_id  # set on dispatch for traceability
      t.timestamps

      t.index [:status, :scheduled_at]
      t.index [:conversation_id, :status]
    end
  end
end
