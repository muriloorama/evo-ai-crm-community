# Parses an inbound WhatsApp webhook payload and extracts first-touch
# attribution data: ad referral (Click-to-WhatsApp), UTM params, or falls
# back to "whatsapp_direct" when the contact just messaged the number.
#
# Called once per contact (first inbound message). Subsequent messages are
# ignored — first-touch is what feeds campaign ROI reports. Rationale: the
# Meta ads platform bills once per conversation opened for this contact, so
# duplicating the tracking on later messages would distort CPL.
#
# Usage:
#   TrackingSources::CaptureService.new(
#     contact: contact,
#     conversation: conversation,
#     inbox: inbox,
#     payload: raw_webhook_params
#   ).perform
class TrackingSources::CaptureService
  pattr_initialize [:contact!, :conversation, :inbox, :payload!]

  def perform
    return nil unless contact.account_id.present?
    return nil if TrackingSource.unscoped.exists?(account_id: contact.account_id, contact_id: contact.id)

    attrs = parse_attributes
    TrackingSource.create!(
      account_id:      contact.account_id,
      contact_id:      contact.id,
      conversation_id: conversation&.id,
      inbox_id:        inbox&.id,
      captured_at:     Time.current,
      **attrs
    )
  rescue ActiveRecord::RecordNotUnique
    # Concurrent first-message race — ignore, one already won
    nil
  rescue StandardError => e
    Rails.logger.warn "[TrackingSources::CaptureService] skipped (#{e.class}): #{e.message}"
    nil
  end

  # Walks the payload looking for Meta referral fields, UTM params, or
  # anything that hints at the entry channel. Returns a hash of attrs.
  def parse_attributes
    referral = find_referral
    utms     = find_utms
    utms     = find_utms_in_message_body if utms.empty?
    # Prefer the referral's own click-id when we have one — it's the narrow
    # ad-click identifier that matches what Meta Ads Manager reports. Falling
    # back to `deep_find` only for payloads that don't carry an externalAdReply
    # (e.g. plain UTM-tagged WhatsApp direct links).
    ctwa_clid = (referral.is_a?(Hash) && referral['ctwa_clid'].presence) ||
                deep_find(payload, %w[ctwa_clid ctwaClid ctwa_click_id ctwaPayload])

    source_type = classify(referral, utms, ctwa_clid)

    attrs = {
      source_type:  source_type,
      source_label: build_label(source_type, referral, utms),
      ctwa_clid:    ctwa_clid,
      raw_payload:  sanitize_for_storage(payload)
    }

    if referral.is_a?(Hash)
      attrs.merge!(
        campaign_id:           referral['source_id']     || referral['campaign_id'],
        campaign_name:         referral['campaign_name'] || referral['headline'],
        ad_id:                 referral['ad_id'],
        adset_id:              referral['adset_id'],
        ad_headline:           referral['headline'],
        ad_body:               referral['body'],
        ad_media_type:         referral['media_type'],
        ad_creative_url:       referral['image_url'] || referral['video_url'] || referral['thumbnail_url'],
        ad_creative_thumbnail: build_thumbnail_data_uri(referral['thumbnail_b64']),
        landing_url:           referral['source_url']
      )
    end

    if utms.any?
      attrs.merge!(
        utm_source:   utms['utm_source'],
        utm_medium:   utms['utm_medium'],
        utm_campaign: utms['utm_campaign'],
        utm_content:  utms['utm_content'],
        utm_term:     utms['utm_term']
      )
    end

    attrs
  end

  def find_referral
    # Check the common locations across WhatsApp providers. Meta Cloud API
    # sends the referral at the top of `message`; Baileys-style providers
    # (Evolution, uazapi) nest it inside `contextInfo.externalAdReply`; and
    # uazapi specifically wraps message bodies under `content`, adding an
    # extra hop — so the externalAdReply ends up at
    # `message.content.contextInfo.externalAdReply`.
    candidates = [
      payload.dig(:message, :referral),
      payload.dig('message', 'referral'),
      payload[:referral],
      payload['referral'],
      payload.dig(:entry, 0, :changes, 0, :value, :messages, 0, :referral),
      payload.dig(:message, :contextInfo, :externalAdReply),
      payload.dig('message', 'contextInfo', 'externalAdReply'),
      payload.dig(:message, :content, :contextInfo, :externalAdReply),
      payload.dig('message', 'content', 'contextInfo', 'externalAdReply')
    ]
    raw = candidates.compact.first
    return normalize_external_ad_reply(raw) if raw.is_a?(Hash)

    find_uazapi_ctwa
  end

  # externalAdReply uses camelCase keys (sourceID, sourceType, ctwaClid).
  # The rest of the pipeline expects snake_case. Translate once here so
  # downstream code doesn't have to know the payload origin.
  def normalize_external_ad_reply(referral)
    {
      'source_type'     => (referral['sourceType'] || referral['source_type']).to_s,
      'source_id'       => referral['sourceID']     || referral['source_id'],
      'source_url'      => referral['sourceURL']    || referral['source_url'],
      'source_app'      => referral['sourceApp']    || referral['source_app'],
      'ctwa_clid'       => referral['ctwaClid']     || referral['ctwa_clid'],
      'headline'        => referral['title']        || referral['headline'],
      'body'            => referral['body'],
      'media_type'      => referral['mediaType']    || referral['media_type'],
      'thumbnail_url'   => referral['thumbnailURL'] || referral['thumbnail_url'],
      'thumbnail_b64'   => referral['thumbnail']    || referral['thumbnailB64'],
      'campaign_id'     => referral['campaignId']   || referral['campaign_id'] || referral['sourceID'],
      'campaign_name'   => referral['campaignName'] || referral['campaign_name']
    }.compact
  end

  # uazapi puts the Meta CTWA signals under `message.content.contextInfo` with
  # fields like conversionSource, entryPointConversionApp, ctwaPayload.
  # The ad metadata itself (campaign/ad IDs, headline) is encrypted inside
  # ctwaPayload — we can't decode it here, but we can still flag the source
  # and store the opaque signals for later reconciliation.
  # Wraps the raw base64 thumbnail in a data URI so the frontend can drop it
  # directly into an <img src>. Callers pass the raw base64 string (no prefix)
  # as delivered by uazapi/Baileys.
  def build_thumbnail_data_uri(b64)
    return nil if b64.blank?
    return b64 if b64.start_with?('data:')

    "data:image/jpeg;base64,#{b64}"
  end

  def find_uazapi_ctwa
    ctx = payload.dig(:message, :content, :contextInfo) ||
          payload.dig('message', 'content', 'contextInfo')
    return nil unless ctx.is_a?(Hash)

    conversion_source = ctx['conversionSource'] || ctx[:conversionSource]
    entry_point       = ctx['entryPointConversionSource'] || ctx[:entryPointConversionSource]
    return nil unless conversion_source.present? || entry_point.to_s.include?('ctwa')

    app = (ctx['entryPointConversionApp'] || ctx[:entryPointConversionApp]).to_s.downcase
    {
      'source_type'  => app.include?('instagram') ? 'instagram' : 'meta',
      'source_id'    => ctx['ctwaPayload'] || ctx[:ctwaPayload],
      'headline'     => entry_point.presence || conversion_source,
      'body'         => nil,
      'media_type'   => nil,
      'source_url'   => app.include?('instagram') ? 'instagram.com' : 'facebook.com'
    }
  end

  def find_utms
    url = deep_find(payload, %w[source_url landing_url referrer_url url])
    return {} unless url.is_a?(String) && url.include?('utm_')

    begin
      require 'uri'
      params = URI.decode_www_form(URI.parse(url).query.to_s).to_h
      params.select { |k, _| k.to_s.start_with?('utm_') }
    rescue StandardError
      {}
    end
  end

  # Fallback: parse `#utm_*=value` hashtags embedded in the first WhatsApp
  # message body. Lets landing pages inject campaign info into the pre-filled
  # text (wa.me/xxx?text=...%23utm_source%3Dmeta...) when there's no CTWA
  # referral or URL-based UTM.
  def find_utms_in_message_body
    body = deep_find(
      payload,
      %w[conversation text body caption message_body]
    )
    return {} unless body.is_a?(String) && body.include?('#utm_')

    body.scan(/#(utm_[a-z]+)\s*=\s*([^\s#]+)/i).to_h
  end

  def classify(referral, utms, ctwa_clid)
    if referral.is_a?(Hash) && referral.any?
      stype = referral['source_type'].to_s.downcase
      platform = referral['source_url'].to_s.downcase
      return 'instagram_ad' if platform.include?('instagram') || stype.include?('instagram')
      return 'meta_ad'
    end

    return 'meta_ad' if ctwa_clid.present?

    if utms.any?
      src = utms['utm_source'].to_s.downcase
      return 'instagram_ad' if src.include?('instagram') || src == 'ig'
      return 'meta_ad'       if %w[meta facebook fb].include?(src)
      return 'organic'
    end

    'whatsapp_direct'
  end

  def build_label(source_type, referral, utms)
    if referral.is_a?(Hash)
      name = referral['campaign_name'] || referral['headline'] || referral['source_id']
      return "Meta: #{name}" if name.present? && source_type == 'meta_ad'
      return "Instagram: #{name}" if name.present? && source_type == 'instagram_ad'
    end

    if utms.any?
      parts = [utms['utm_source'], utms['utm_campaign']].compact.reject(&:empty?)
      return parts.join(' - ') if parts.any?
    end

    {
      'meta_ad'         => 'Meta Ads',
      'instagram_ad'    => 'Instagram Ads',
      'whatsapp_direct' => 'WhatsApp direto',
      'organic'         => 'Orgânico',
      'other'           => 'Outros',
      'unknown'         => 'Desconhecido'
    }[source_type]
  end

  # Recursive search inside nested hashes/arrays for any of the given keys.
  def deep_find(obj, keys)
    return nil if obj.nil?

    case obj
    when Hash
      obj.each do |k, v|
        return v if keys.include?(k.to_s) && v.present? && !v.is_a?(Hash) && !v.is_a?(Array)
        found = deep_find(v, keys)
        return found if found.present?
      end
    when Array
      obj.each do |item|
        found = deep_find(item, keys)
        return found if found.present?
      end
    end
    nil
  end

  # Keep the raw payload small — trim to essentials so the jsonb column
  # doesn't balloon with base64-encoded media previews.
  def sanitize_for_storage(obj, depth = 0)
    return '[truncated]' if depth > 4

    case obj
    when Hash
      obj.each_with_object({}) do |(k, v), out|
        next if v.is_a?(String) && v.length > 500
        out[k] = sanitize_for_storage(v, depth + 1)
      end
    when Array
      obj.first(10).map { |item| sanitize_for_storage(item, depth + 1) }
    when String
      obj.length > 500 ? obj.first(500) + '…' : obj
    else
      obj
    end
  end
end
