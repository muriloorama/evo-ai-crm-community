# frozen_string_literal: true

# Replaces the MAX(display_id)+1 strategy in Conversation#ensure_display_id
# with a monotonic counter per account. The previous approach reused IDs
# whenever the highest-numbered conversation got deleted (delete #11 → next
# new conversation also lands at #11), which surfaced as "this is a brand new
# chat but it shows the URL of the old one I just trashed".
#
# The counter is backfilled with the current max per account so existing
# numbering continues from where it left off.
class CreateConversationDisplayIdCounters < ActiveRecord::Migration[7.1]
  def up
    create_table :conversation_display_id_counters, id: false do |t|
      t.uuid :account_id, null: false, primary_key: true
      t.integer :next_value, null: false, default: 1
      t.datetime :updated_at, null: false, default: -> { 'now()' }
    end

    add_foreign_key :conversation_display_id_counters, :accounts, on_delete: :cascade if foreign_key_exists?(:conversations, :accounts)

    execute(<<~SQL)
      INSERT INTO conversation_display_id_counters (account_id, next_value, updated_at)
      SELECT account_id, COALESCE(MAX(display_id), 0), NOW()
      FROM conversations
      GROUP BY account_id;
    SQL
  end

  def down
    drop_table :conversation_display_id_counters
  end
end
