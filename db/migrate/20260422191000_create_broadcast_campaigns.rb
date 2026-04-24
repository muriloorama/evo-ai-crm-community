class CreateBroadcastCampaigns < ActiveRecord::Migration[7.1]
  def change
    create_table :broadcast_campaigns, id: :uuid do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid
      t.references :inbox, null: false, foreign_key: true, type: :uuid
      t.references :created_by, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.string :name, null: false
      # snapshot of the approved template at send-time so campaign reports
      # stay accurate even if the template changes later.
      t.string :template_name
      t.string :template_language
      t.jsonb :template_params, default: {} # per-recipient defaults
      t.integer :status, null: false, default: 0  # 0=draft, 1=queued, 2=running, 3=completed, 4=cancelled, 5=failed
      t.datetime :scheduled_at
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :total_recipients, default: 0
      t.integer :sent_count, default: 0
      t.integer :failed_count, default: 0
      # Rate limit knob — per-minute cap that ensures we stay under Meta's
      # messaging tier limits regardless of how many recipients were added.
      t.integer :rate_limit_per_minute, default: 60
      t.text :error_message
      t.timestamps

      t.index [:account_id, :status]
      t.index [:status, :scheduled_at]
    end

    create_table :broadcast_recipients, id: :uuid do |t|
      t.references :broadcast_campaign, null: false, foreign_key: true, type: :uuid, index: { name: 'idx_broadcast_recipients_campaign' }
      t.references :contact, null: false, foreign_key: true, type: :uuid
      t.jsonb :template_params_override, default: {} # recipient-specific variable values
      t.integer :status, null: false, default: 0  # 0=pending, 1=sent, 2=failed, 3=skipped
      t.datetime :sent_at
      t.string :message_source_id
      t.text :error_message
      t.timestamps

      t.index [:broadcast_campaign_id, :status], name: 'idx_broadcast_recipients_status'
    end
  end
end
