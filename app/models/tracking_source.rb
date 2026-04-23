# == Schema Information
#
# Table name: tracking_sources
#
#  id                    :uuid             not null, primary key
#  ad_body               :text
#  ad_creative_thumbnail :text
#  ad_creative_url       :string
#  ad_headline           :string
#  ad_media_type         :string
#  campaign_name         :string
#  captured_at           :datetime         not null
#  ctwa_clid             :string
#  landing_url           :string
#  raw_payload           :jsonb            not null
#  referrer_url          :string
#  source_label          :string
#  source_type           :string           default("unknown"), not null
#  utm_campaign          :string
#  utm_content           :string
#  utm_medium            :string
#  utm_source            :string
#  utm_term              :string
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :uuid             not null
#  ad_id                 :string
#  adset_id              :string
#  campaign_id           :string
#  contact_id            :uuid             not null
#  conversation_id       :uuid
#  inbox_id              :uuid
#
# Indexes
#
#  idx_tracking_unique_contact                (account_id,contact_id) UNIQUE
#  index_tracking_sources_on_account_id       (account_id)
#  index_tracking_sources_on_campaign_id      (campaign_id)
#  index_tracking_sources_on_captured_at      (captured_at)
#  index_tracking_sources_on_conversation_id  (conversation_id)
#  index_tracking_sources_on_source_type      (source_type)
#
class TrackingSource < ApplicationRecord
  SOURCE_TYPES = %w[meta_ad instagram_ad whatsapp_direct organic other unknown].freeze

  belongs_to :contact
  belongs_to :conversation, optional: true
  belongs_to :inbox, optional: true

  validates :source_type, presence: true, inclusion: { in: SOURCE_TYPES }
  validates :captured_at, presence: true
  validates :contact_id, uniqueness: { scope: :account_id }

  # URLs e payloads de anúncio Meta frequentemente passam de 255 chars
  # (thumbnails fbcdn, landing URLs com UTM, etc.). Essas validações
  # explícitas substituem o length default de 255 do ApplicationRecord.
  validates :ad_creative_url, :landing_url, :referrer_url,
            :campaign_name, :ad_headline, :ad_id, :adset_id, :campaign_id,
            :ctwa_clid, :source_label,
            :utm_source, :utm_medium, :utm_campaign, :utm_content, :utm_term,
            length: { maximum: 2048 }, allow_nil: true

  scope :by_source_type, ->(type) { where(source_type: type) }
  scope :in_period,      ->(range) { where(captured_at: range) }

  def paid?
    %w[meta_ad instagram_ad].include?(source_type)
  end

  def organic?
    %w[whatsapp_direct organic].include?(source_type)
  end
end
