# frozen_string_literal: true

# Multi-account foundation: adds `account_id` (UUID, FK to Auth service's
# `accounts` table) to every data table that belongs to a specific tenant.
#
# Strategy:
#   1. Require the `accounts` table to exist (created by the Auth service).
#   2. Require at least one Account row — used to backfill existing data.
#   3. Add the column nullable, backfill to the default account, then enforce
#      NOT NULL + FK + index.
#
# Descendants that are always loaded through a parent (e.g. attachments
# through messages) also get account_id to keep Accountable default_scope
# effective and prevent cross-account leaks when queried directly.
class AddAccountIdToDataTables < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  TABLES = %w[
    agent_bots
    automation_rules
    canned_responses
    channel_api
    channel_email
    channel_facebook_pages
    channel_instagram
    channel_line
    channel_sms
    channel_telegram
    channel_twilio_sms
    channel_twitter_profiles
    channel_web_widgets
    channel_whatsapp
    contact_companies
    contact_inboxes
    contacts
    conversation_participants
    conversations
    csat_survey_responses
    custom_attribute_definitions
    custom_filters
    dashboard_apps
    data_imports
    inbox_members
    inboxes
    integrations_hooks
    labels
    macros
    mentions
    message_templates
    messages
    notes
    notification_settings
    notifications
    pipeline_items
    pipeline_stages
    pipelines
    reporting_events
    scheduled_action_templates
    scheduled_actions
    tags
    team_members
    teams
    telegram_bots
    webhooks
    working_hours
  ].freeze

  def up
    unless connection.table_exists?(:accounts)
      raise 'accounts table not found. Run the Auth service migrations first.'
    end

    default_account_id = connection.select_value(
      "SELECT id FROM accounts ORDER BY created_at LIMIT 1"
    )
    raise 'No Account row exists. Seed the Auth service first.' if default_account_id.blank?

    TABLES.each do |table|
      next unless connection.table_exists?(table)
      next if column_exists?(table, :account_id)

      add_column table, :account_id, :uuid
    end

    TABLES.each do |table|
      next unless connection.table_exists?(table)

      connection.execute(
        "UPDATE #{connection.quote_table_name(table)} " \
        "SET account_id = #{connection.quote(default_account_id)} " \
        'WHERE account_id IS NULL'
      )

      change_column_null table, :account_id, false

      unless foreign_key_exists?(table, :accounts, column: :account_id)
        add_foreign_key table, :accounts, column: :account_id, on_delete: :cascade
      end

      index_name = "index_#{table}_on_account_id"
      unless index_name_exists?(table, index_name)
        add_index table, :account_id, name: index_name, algorithm: :concurrently
      end
    end
  end

  def down
    TABLES.each do |table|
      next unless connection.table_exists?(table)
      next unless column_exists?(table, :account_id)

      if foreign_key_exists?(table, :accounts, column: :account_id)
        remove_foreign_key table, :accounts, column: :account_id
      end

      index_name = "index_#{table}_on_account_id"
      remove_index table, name: index_name if index_name_exists?(table, index_name)

      remove_column table, :account_id
    end
  end
end
