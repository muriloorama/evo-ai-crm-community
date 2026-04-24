# Pulls campaign-level insights from Meta Ads and upserts them into
# `campaign_investments` so the Dashboard "Rastreamento" tab shows real
# spend per campaign without manual input.
#
# Match key: `campaign_investments.campaign_key` = Meta `campaign_id`
# (same value captured by `TrackingSources::CaptureService` from incoming
# Click-to-WhatsApp ads), so charts join automatically.
#
# Period: last 60 days by default (matches token TTL).
class MetaAds::SyncService
  DEFAULT_LOOKBACK_DAYS = 60
  # Pull insights at the ad level so each creative shows up as its own row in
  # the dashboard. Aggregating at `level: 'campaign'` collapsed multiple ads
  # under their parent and hid creatives the operator wanted to compare.
  INSIGHTS_FIELDS = 'ad_id,ad_name,adset_id,adset_name,campaign_id,campaign_name,spend,impressions,reach,clicks,date_start,date_stop'.freeze

  def initialize(meta_account, lookback_days: DEFAULT_LOOKBACK_DAYS)
    @account = meta_account
    @lookback_days = lookback_days
    @client = MetaAds::ApiClient.new(@account.access_token)
  end

  def call
    Accountable.with_account(@account.account_id) do
      since_date = @lookback_days.days.ago.to_date
      until_date = Date.current

      ads = fetch_ad_insights(since_date, until_date)
      upsert_count = upsert_investments(ads, since_date, until_date)
      enrich_creatives(ads.map { |r| r['ad_id'] }.compact.uniq)

      @account.update!(
        last_sync_at: Time.current,
        last_sync_status: 'ok',
        last_sync_error: nil,
        last_sync_campaigns_count: upsert_count
      )

      { ok: true, campaigns_synced: upsert_count, period: { since: since_date, until: until_date } }
    end
  rescue MetaAds::ApiClient::ApiError => e
    @account.update!(last_sync_at: Time.current, last_sync_status: 'error', last_sync_error: e.message)
    { ok: false, error: e.message }
  rescue StandardError => e
    Rails.logger.error("[MetaAds::SyncService] #{e.class}: #{e.message}")
    @account.update!(last_sync_at: Time.current, last_sync_status: 'error', last_sync_error: e.message)
    { ok: false, error: e.message }
  end

  private

  def fetch_ad_insights(since_date, until_date)
    rows = []
    @client.paginate(
      "/#{@account.ad_account_id}/insights",
      level: 'ad',
      fields: INSIGHTS_FIELDS,
      time_range: { since: since_date.to_s, until: until_date.to_s }.to_json,
      limit: 200
    ) { |page| rows.concat(page) }
    rows
  end

  def upsert_investments(rows, since_date, until_date)
    count = 0
    rows.each do |row|
      ad_id = row['ad_id']
      next unless ad_id

      # Idempotent per ad: one row per (account, ad_id). The CTWA tracking
      # source stores Meta's `sourceID` (= ad_id) in `campaign_id`, so the
      # dashboard join works when `campaign_key` holds the same value.
      record = CampaignInvestment.find_or_initialize_by(
        account_id: @account.account_id,
        campaign_key: ad_id
      )

      # Prefer the ad name as the displayed "campaign"; fall back to the
      # parent campaign's name if the ad is unnamed.
      display_name = row['ad_name'].presence || row['campaign_name']

      record.assign_attributes(
        campaign_name: display_name,
        source_type: detect_source_type(display_name),
        amount: row['spend'].to_f,
        currency: @account.currency || 'BRL',
        period_start: since_date,
        period_end: until_date,
        impressions: row['impressions'].to_i,
        reach: row['reach'].to_i,
        clicks: row['clicks'].to_i,
        notes: "Auto-sync Meta · ad #{ad_id} · #{since_date}..#{until_date}"
      )
      record.save!
      count += 1
    end
    count
  end

  # Light heuristic: campaigns whose name mentions Instagram are tagged as
  # `instagram_ad`; everything else falls under `meta_ad`. The Graph API
  # doesn't return a per-campaign platform breakdown without an extra call.
  def detect_source_type(name)
    return 'instagram_ad' if name.to_s.downcase.include?('instagram')
    'meta_ad'
  end

  # Pull the creative for each ad directly (one request per ad id). At the
  # campaign level this used to grab "the first ad with a creative" as a
  # proxy for the campaign's look — fine back when the dashboard row was the
  # campaign. Now each row is the ad itself, so we fetch its own creative.
  def enrich_creatives(ad_ids)
    ad_ids.each do |ad_id|
      ad = fetch_ad_with_creative(ad_id)
      next unless ad

      creative = ad['creative'] || {}
      permalink = object_story_permalink(creative['effective_object_story_id'])
      creative_url = resolve_creative_url(creative)

      record = CampaignInvestment.find_by(
        account_id: @account.account_id,
        campaign_key: ad_id
      )
      next unless record

      record.update!(
        ad_creative_url:  creative_url,
        ad_headline:      creative['title'] || ad['name'],
        ad_body:          creative['body'],
        ad_permalink_url: permalink,
        ad_status:        ad['effective_status'] || ad['status']
      )
    rescue MetaAds::ApiClient::ApiError => e
      # One bad ad shouldn't abort the whole enrichment pass
      Rails.logger.warn("[MetaAds::SyncService] creative enrich skipped for ad #{ad_id}: #{e.message}")
    end
  end

  def fetch_ad_with_creative(ad_id)
    @client.get(
      "/#{ad_id}",
      fields: 'name,status,effective_status,creative{title,body,image_url,image_hash,thumbnail_url,object_story_spec,asset_feed_spec,effective_object_story_id}'
    )
  end

  def creative_has_visual?(creative)
    return false unless creative.is_a?(Hash)
    creative['image_url'].present? ||
      creative['image_hash'].present? ||
      creative.dig('object_story_spec', 'link_data', 'image_hash').present? ||
      creative.dig('asset_feed_spec', 'images', 0, 'hash').present? ||
      creative['thumbnail_url'].present?
  end

  # Meta returns three candidate URLs per creative, in increasing quality:
  #   thumbnail_url  → ~64-128px preview
  #   image_url      → original upload (often nil for post-boost / carousel)
  #   /adimages?hashes=[hash] → same-quality but public signed URL
  # Prefer image_url; then resolve the hash via /adimages (1080px+); fall back
  # to the thumbnail as last resort.
  def resolve_creative_url(creative)
    return creative['image_url'] if creative['image_url'].present?

    hash = creative['image_hash'] ||
           creative.dig('object_story_spec', 'link_data', 'image_hash') ||
           creative.dig('asset_feed_spec', 'images', 0, 'hash')

    if hash.present?
      begin
        result = @client.get(
          "/#{@account.ad_account_id}/adimages",
          hashes: [hash].to_json,
          fields: 'url,permalink_url,width,height'
        )
        img = (result['data'] || []).first
        return img['url'] if img && img['url'].present?
      rescue MetaAds::ApiClient::ApiError => e
        Rails.logger.warn("[MetaAds::SyncService] adimages lookup failed for #{hash}: #{e.message}")
      end
    end

    creative['thumbnail_url']
  end

  # `effective_object_story_id` is "<page_id>_<post_id>" for Facebook and an
  # Instagram media ID for Instagram-only ads. We build a permalink that works
  # for the common cases and fall back to nil when the shape is unknown.
  def object_story_permalink(story_id)
    return nil if story_id.blank?

    if story_id.include?('_')
      "https://www.facebook.com/#{story_id.tr('_', '/posts/')}"
    else
      "https://www.instagram.com/p/#{story_id}/"
    end
  end
end
