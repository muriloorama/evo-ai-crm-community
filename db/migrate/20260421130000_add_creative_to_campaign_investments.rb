class AddCreativeToCampaignInvestments < ActiveRecord::Migration[7.1]
  def change
    # text instead of varchar: Meta Graph creative URLs include signed tokens
    # and routinely exceed the default 255-char limit.
    add_column :campaign_investments, :ad_creative_url,  :text
    add_column :campaign_investments, :ad_headline,      :text
    add_column :campaign_investments, :ad_body,          :text
    add_column :campaign_investments, :ad_permalink_url, :text
  end
end
