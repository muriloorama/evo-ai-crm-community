# frozen_string_literal: true

# Patches the omission in 20260417150000_add_account_id_to_data_tables — the
# `agent_bot_inboxes` join table was left out of the original list, so the
# Accountable concern installed on AgentBotInbox kept asking the DB for a
# column that didn't exist (queries crashed with PG::UndefinedColumn).
#
# Backfills account_id from the parent inbox before locking the column down.
class AddAccountIdToAgentBotInboxes < ActiveRecord::Migration[7.1]
  def up
    return if column_exists?(:agent_bot_inboxes, :account_id)

    add_column :agent_bot_inboxes, :account_id, :uuid

    connection.execute(<<~SQL.squish)
      UPDATE agent_bot_inboxes abi
      SET account_id = i.account_id
      FROM inboxes i
      WHERE abi.inbox_id = i.id
        AND abi.account_id IS NULL
    SQL

    # If any join rows have no parent inbox, fall back to the first account.
    default_account_id = connection.select_value("SELECT id FROM accounts ORDER BY created_at LIMIT 1")
    connection.execute(
      "UPDATE agent_bot_inboxes SET account_id = #{connection.quote(default_account_id)} WHERE account_id IS NULL"
    ) if default_account_id

    change_column_null :agent_bot_inboxes, :account_id, false
    add_foreign_key :agent_bot_inboxes, :accounts, column: :account_id, on_delete: :cascade
    add_index :agent_bot_inboxes, :account_id, name: 'index_agent_bot_inboxes_on_account_id'
  end

  def down
    return unless column_exists?(:agent_bot_inboxes, :account_id)

    if foreign_key_exists?(:agent_bot_inboxes, :accounts, column: :account_id)
      remove_foreign_key :agent_bot_inboxes, :accounts, column: :account_id
    end
    remove_index :agent_bot_inboxes, name: 'index_agent_bot_inboxes_on_account_id' if index_name_exists?(:agent_bot_inboxes, 'index_agent_bot_inboxes_on_account_id')
    remove_column :agent_bot_inboxes, :account_id
  end
end
