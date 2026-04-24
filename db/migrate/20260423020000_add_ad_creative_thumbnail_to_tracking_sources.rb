class AddAdCreativeThumbnailToTrackingSources < ActiveRecord::Migration[7.1]
  # Meta/Instagram deliver the ad creative via a CDN URL that expires in a
  # handful of hours. The webhook also carries a base64-encoded thumbnail
  # that never expires — small (~5-15 KB) and perfect as a stable fallback.
  # We store it raw so the frontend can swap to a `data:image/...;base64,`
  # URI if the CDN link 404s later.
  def change
    add_column :tracking_sources, :ad_creative_thumbnail, :text
  end
end
