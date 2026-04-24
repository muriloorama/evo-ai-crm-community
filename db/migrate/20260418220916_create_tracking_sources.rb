class CreateTrackingSources < ActiveRecord::Migration[7.1]
  def change
    create_table :tracking_sources, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.uuid :account_id, null: false
      t.uuid :contact_id, null: false
      t.uuid :conversation_id
      t.uuid :inbox_id

      # Origin classification — coarse bucket for aggregation
      # meta_ad | instagram_ad | whatsapp_direct | organic | other
      t.string :source_type, null: false, default: 'unknown'
      t.string :source_label   # human-friendly ("Meta - Black Friday Colchões")

      # Click-to-WhatsApp (Meta/Instagram ads) fields
      t.string :ctwa_clid
      t.string :campaign_id
      t.string :campaign_name
      t.string :ad_id
      t.string :adset_id
      t.string :ad_headline
      t.text   :ad_body
      t.string :ad_media_type   # image / video
      t.string :ad_creative_url

      # Generic UTM (for organic links / external sources)
      t.string :utm_source
      t.string :utm_medium
      t.string :utm_campaign
      t.string :utm_content
      t.string :utm_term

      # Landing context
      t.string :referrer_url
      t.string :landing_url

      # Full raw payload (for debugging + future reprocessing)
      t.jsonb :raw_payload, default: {}, null: false

      t.datetime :captured_at, null: false
      t.timestamps
    end

    # First-touch: one tracking per contact per account (unique)
    add_index :tracking_sources, [:account_id, :contact_id], unique: true, name: 'idx_tracking_unique_contact'
    add_index :tracking_sources, :conversation_id
    add_index :tracking_sources, :source_type
    add_index :tracking_sources, :campaign_id
    add_index :tracking_sources, :captured_at
    add_index :tracking_sources, :account_id
  end
end
