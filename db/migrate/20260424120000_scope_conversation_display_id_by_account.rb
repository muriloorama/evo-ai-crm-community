# frozen_string_literal: true

# Converts `conversations.display_id` from globally unique to unique per
# account — the Chatwoot-style identifier users see in URLs like
# /app/accounts/7/conversations/42. The UUID `id` stays the primary key; only
# the visible number is renumbered.
#
# Existing conversations are renumbered per account in chronological order
# so the oldest conversation in each workspace becomes display_id #1.
class ScopeConversationDisplayIdByAccount < ActiveRecord::Migration[7.1]
  def up
    # Drop the old globally-unique index before renumbering — otherwise the
    # intermediate UPDATE values collide as we write new numbers.
    remove_index :conversations, name: :index_conversations_on_display_id if index_exists?(:conversations, :display_id, name: :index_conversations_on_display_id)

    # Renumber all existing conversations so display_id restarts at 1 per
    # account, ordered by creation time. This rewrites history — acceptable
    # because the platform is still in development with no customer-facing
    # deep links yet.
    execute(<<~SQL)
      WITH renumbered AS (
        SELECT id, ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY created_at ASC, id ASC) AS n
        FROM conversations
      )
      UPDATE conversations
      SET display_id = renumbered.n
      FROM renumbered
      WHERE conversations.id = renumbered.id;
    SQL

    add_index :conversations, %i[account_id display_id], unique: true, name: :index_conversations_on_account_id_and_display_id
  end

  def down
    remove_index :conversations, name: :index_conversations_on_account_id_and_display_id if index_exists?(:conversations, %i[account_id display_id], name: :index_conversations_on_account_id_and_display_id)

    # Restore globally-unique display_id by renumbering across the whole table.
    execute(<<~SQL)
      WITH renumbered AS (
        SELECT id, ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) AS n
        FROM conversations
      )
      UPDATE conversations
      SET display_id = renumbered.n
      FROM renumbered
      WHERE conversations.id = renumbered.id;
    SQL

    add_index :conversations, :display_id, unique: true, name: :index_conversations_on_display_id
  end
end
