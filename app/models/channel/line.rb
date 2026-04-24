# == Schema Information
#
# Table name: channel_line
#
#  id                  :uuid             not null, primary key
#  line_channel_secret :string           not null
#  line_channel_token  :string           not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :uuid             not null
#  line_channel_id     :string           not null
#
# Indexes
#
#  index_channel_line_on_account_id       (account_id)
#  index_channel_line_on_line_channel_id  (line_channel_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#

class Channel::Line < ApplicationRecord
  include Channelable
  include ChannelMessageTemplates

  self.table_name = 'channel_line'
  EDITABLE_ATTRS = [:line_channel_id, :line_channel_secret, :line_channel_token].freeze

  validates :line_channel_id, uniqueness: true, presence: true
  validates :line_channel_secret, presence: true
  validates :line_channel_token, presence: true

  def name
    'LINE'
  end

  def client
    @client ||= Line::Bot::Client.new do |config|
      config.channel_id = line_channel_id
      config.channel_secret = line_channel_secret
      config.channel_token = line_channel_token
    end
  end
end
