# Aggregates first-touch attribution data for the Dashboard "Rastreamento"
# tab. Returns lead counts by source/campaign, pipeline funnel, ROI when
# investment is available, and conversion %.
#
# Conventions:
#   - "Conversion" = lead reached a stage marked as won (default: stage named
#     "Concluído"). "Lost" = stage named "Perdido". Stage matching is by name
#     so it works across pipelines without extra config.
#   - "Revenue" = sum of `pipeline_items.custom_fields.services` values for
#     converted items.
class Reports::TrackingSummaryService
  WON_STAGE_NAMES  = ['Concluído', 'Concluido', 'Vendido', 'Won'].freeze
  LOST_STAGE_NAMES = ['Perdido', 'Lost'].freeze

  # `account_timezone` defaults to `America/Sao_Paulo` so date filters map to
  # the operator's local day. Without this, a conversation opened at 22:00 BRT
  # on day X (= 01:00 UTC on day X+1) gets excluded from reports covering
  # "up to day X", which surprises the operator.
  def initialize(account_id:, start_date: nil, end_date: nil, pipeline_id: nil, source_type: nil, account_timezone: 'America/Sao_Paulo')
    @account_id  = account_id
    @tz          = ActiveSupport::TimeZone[account_timezone] || Time.zone
    @start_date  = (start_date.presence ? Date.parse(start_date.to_s) : 30.days.ago.to_date)
    @end_date    = (end_date.presence ? Date.parse(end_date.to_s) : Date.current)
    @pipeline_id = pipeline_id.presence
    @source_type = source_type.presence
  end

  def call
    Accountable.with_account(@account_id) do
      sources = filtered_sources.to_a
      converted_contact_ids = converted_contacts_in_period.pluck(:contact_id).uniq
      lost_contact_ids      = lost_contacts_in_period.pluck(:contact_id).uniq

      revenue_by_contact = revenue_per_converted_contact(converted_contact_ids)
      total_revenue      = revenue_by_contact.values.sum

      total_leads = sources.size
      total_won   = (sources.map(&:contact_id) & converted_contact_ids).size
      total_lost  = (sources.map(&:contact_id) & lost_contact_ids).size
      conversion_rate = total_leads.zero? ? 0 : (total_won.to_f / total_leads * 100).round(1)

      {
        period: { start: @start_date, end: @end_date },
        totals: {
          leads: total_leads,
          paid_leads: sources.count(&:paid?),
          organic_leads: sources.count(&:organic?),
          won: total_won,
          lost: total_lost,
          conversion_rate: conversion_rate,
          revenue: total_revenue.to_f,
          investment: total_investment.to_f,
          roi_percent: roi_percent(total_revenue, total_investment),
          cpl: cost_per_lead(total_leads, total_investment)
        },
        by_source: by_source_breakdown(sources, converted_contact_ids, revenue_by_contact),
        # Merge ads that had leads + ads that ran without leads (so the
        # operator still sees spend that hasn't converted yet). Dedup by
        # campaign_key so we don't double-count if something changes upstream.
        by_campaign: merge_campaign_rows(
          by_campaign_breakdown(sources, converted_contact_ids, revenue_by_contact),
          investments_without_leads(sources)
        ),
        funnel: funnel_breakdown(sources)
      }
    end
  end


  private

  # Start of the filter window in account-local TZ, converted to UTC so the
  # SQL range matches the `timestamp without time zone` columns. Without
  # this, a contact who clicks the ad at 22:00 BRT (= 01:00 UTC next day)
  # falls off a report that ends "today" in the operator's local calendar.
  def window_start
    @tz.local(@start_date.year, @start_date.month, @start_date.day, 0, 0, 0).utc
  end

  def window_end
    @tz.local(@end_date.year, @end_date.month, @end_date.day, 23, 59, 59).utc
  end

  def filtered_sources
    scope = TrackingSource.where(account_id: @account_id)
                          .where(captured_at: window_start..window_end)
    scope = scope.where(source_type: @source_type) if @source_type
    scope
  end

  def converted_contacts_in_period
    pipeline_items_for_stages(WON_STAGE_NAMES)
  end

  def lost_contacts_in_period
    pipeline_items_for_stages(LOST_STAGE_NAMES)
  end

  def pipeline_items_for_stages(names)
    stages = PipelineStage.where(name: names)
    stages = stages.where(pipeline_id: @pipeline_id) if @pipeline_id
    stage_ids = stages.pluck(:id)
    return PipelineItem.none if stage_ids.empty?

    items = PipelineItem.joins(:conversation)
                        .where(pipeline_stage_id: stage_ids)
                        .where(updated_at: window_start..window_end)
    items.select('pipeline_items.*, conversations.contact_id AS contact_id')
  end

  def revenue_per_converted_contact(contact_ids)
    return {} if contact_ids.empty?

    items = PipelineItem.joins(:conversation)
                        .where(conversations: { contact_id: contact_ids })
                        .where(pipeline_stage_id: PipelineStage.where(name: WON_STAGE_NAMES).select(:id))
    items.each_with_object({}) do |item, acc|
      total = (item.custom_fields&.dig('services') || []).sum { |s| s['value'].to_f }
      next if total.zero?

      contact_id = item.conversation.contact_id
      acc[contact_id] = (acc[contact_id] || 0) + total
    end
  end

  def by_source_breakdown(sources, won_contact_ids, revenue_by_contact)
    grouped = sources.group_by(&:source_type)
    grouped.map do |type, items|
      contact_ids = items.map(&:contact_id)
      won = (contact_ids & won_contact_ids).size
      revenue = contact_ids.sum { |cid| revenue_by_contact[cid] || 0 }
      investment = investment_for_source_type(type)

      {
        source_type: type,
        label: source_label(type),
        leads: items.size,
        won: won,
        conversion_rate: items.empty? ? 0 : (won.to_f / items.size * 100).round(1),
        revenue: revenue.to_f,
        investment: investment.to_f,
        roi_percent: roi_percent(revenue, investment),
        cpl: cost_per_lead(items.size, investment)
      }
    end.sort_by { |r| -r[:leads] }
  end

  def by_campaign_breakdown(sources, won_contact_ids, revenue_by_contact)
    grouped = sources.group_by { |s| s.campaign_id.presence || s.source_label.presence || s.source_type }
    grouped.map do |key, items|
      first = items.first
      contact_ids = items.map(&:contact_id)
      won = (contact_ids & won_contact_ids).size
      revenue = contact_ids.sum { |cid| revenue_by_contact[cid] || 0 }
      metrics = campaign_metrics(key.to_s)
      investment = metrics[:investment]
      impressions = metrics[:impressions]
      clicks = metrics[:clicks]

      # Creative data preference: tracking_source (came from the webhook, most
      # specific to this lead) → campaign_investment (synced from Meta Ads
      # Graph API, same for all leads in the campaign).
      investment_row = metrics[:investment_row]
      creative_url = first.ad_creative_url.presence || investment_row&.ad_creative_url
      headline     = first.ad_headline.presence     || investment_row&.ad_headline
      body         = first.ad_body.presence         || investment_row&.ad_body
      referrer     = first.referrer_url.presence    || investment_row&.ad_permalink_url

      {
        campaign_key:  key.to_s,
        campaign_name: first.campaign_name.presence || investment_row&.campaign_name || first.source_label.presence || key.to_s,
        source_type:   first.source_type,
        leads: items.size,
        won: won,
        conversion_rate: items.empty? ? 0 : (won.to_f / items.size * 100).round(1),
        revenue: revenue.to_f,
        investment: investment.to_f,
        impressions: impressions,
        reach: metrics[:reach],
        clicks: clicks,
        ctr: impressions.zero? ? 0 : (clicks.to_f / impressions * 100).round(2),
        roi_percent: roi_percent(revenue, investment),
        cpl: cost_per_lead(items.size, investment),
        cac: won.zero? ? 0 : (investment.to_f / won).round(2),
        ad_creative_url: creative_url,
        ad_creative_thumbnail: first.ad_creative_thumbnail,
        ad_headline: headline,
        ad_body: body,
        ad_media_type: first.ad_media_type,
        ad_status: investment_row&.ad_status,
        landing_url: first.landing_url,
        referrer_url: referrer
      }
    end.sort_by { |r| -r[:leads] }
  end

  # Investments that have no lead attached yet (ads still running but nobody
  # clicked through to the CRM). The dashboard folds these into `by_campaign`
  # so the operator sees every spend line, not just the ones that converted.
  def investments_without_leads(sources)
    attributed_keys = sources.map(&:campaign_id).compact.uniq
    CampaignInvestment
      .where(account_id: @account_id)
      .where('period_end >= ?', window_start)
      .where.not(campaign_key: attributed_keys)
      .map do |inv|
        {
          campaign_key: inv.campaign_key,
          campaign_name: inv.campaign_name,
          source_type: inv.source_type || 'meta_ad',
          leads: 0, won: 0, conversion_rate: 0,
          revenue: 0.0,
          investment: inv.amount.to_f,
          impressions: inv.impressions,
          reach: inv.reach,
          clicks: inv.clicks,
          ctr: inv.impressions.zero? ? 0 : (inv.clicks.to_f / inv.impressions * 100).round(2),
          roi_percent: -100.0,
          cpl: inv.amount.to_f,
          cac: 0,
          ad_creative_url: inv.ad_creative_url,
          ad_creative_thumbnail: nil,
          ad_headline: inv.ad_headline,
          ad_body: inv.ad_body,
          ad_media_type: nil,
          ad_status: inv.ad_status,
          landing_url: inv.ad_permalink_url,
          referrer_url: inv.ad_permalink_url
        }
      end
  end

  def merge_campaign_rows(with_leads, without_leads)
    seen_keys = with_leads.map { |r| r[:campaign_key] }.to_set
    without_leads.reject! { |r| seen_keys.include?(r[:campaign_key]) }
    (with_leads + without_leads).sort_by { |r| [-r[:leads], -r[:investment]] }
  end

  def funnel_breakdown(sources)
    contact_ids = sources.map(&:contact_id)
    return [] if contact_ids.empty?

    pipeline_scope = PipelineStage.includes(:pipeline)
    pipeline_scope = pipeline_scope.where(pipeline_id: @pipeline_id) if @pipeline_id

    stages = pipeline_scope.order(:position).to_a
    stages.map do |stage|
      count = PipelineItem.joins(:conversation)
                          .where(pipeline_stage_id: stage.id)
                          .where(conversations: { contact_id: contact_ids })
                          .count
      {
        stage_id:   stage.id,
        stage_name: stage.name,
        color:      stage.color,
        position:   stage.position,
        leads:      count
      }
    end
  end

  def total_investment
    @total_investment ||= CampaignInvestment.where(account_id: @account_id)
                                            .overlapping(@start_date..@end_date).sum(:amount)
  end

  def investment_for_source_type(source_type)
    CampaignInvestment.where(account_id: @account_id, source_type: source_type)
                      .overlapping(@start_date..@end_date).sum(:amount)
  end

  def investment_for_campaign_key(key)
    CampaignInvestment.where(account_id: @account_id, campaign_key: key)
                      .overlapping(@start_date..@end_date).sum(:amount)
  end

  def campaign_metrics(key)
    scope = CampaignInvestment.where(account_id: @account_id, campaign_key: key)
                              .overlapping(@start_date..@end_date)
    {
      investment:  scope.sum(:amount),
      impressions: scope.sum(:impressions).to_i,
      reach:       scope.sum(:reach).to_i,
      clicks:      scope.sum(:clicks).to_i,
      investment_row: scope.order(updated_at: :desc).first
    }
  end

  def roi_percent(revenue, investment)
    return 0 if investment.to_f.zero?
    ((revenue.to_f - investment.to_f) / investment.to_f * 100).round(1)
  end

  def cost_per_lead(leads, investment)
    return 0 if leads.zero?
    (investment.to_f / leads).round(2)
  end

  def source_label(source_type)
    {
      'meta_ad'         => 'Meta Ads',
      'instagram_ad'    => 'Instagram Ads',
      'whatsapp_direct' => 'WhatsApp direto',
      'organic'         => 'Orgânico',
      'other'           => 'Outros',
      'unknown'         => 'Desconhecido'
    }[source_type] || source_type.to_s.humanize
  end
end
