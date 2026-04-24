# == Schema Information
#
# Table name: channel_sms
#
#  id              :uuid             not null, primary key
#  phone_number    :string           not null
#  provider        :string           default("default")
#  provider_config :jsonb
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :uuid             not null
#
# Indexes
#
#  index_channel_sms_on_account_id    (account_id)
#  index_channel_sms_on_phone_number  (phone_number) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#

class Channel::Sms < ApplicationRecord
  include Channelable
    include ChannelMessageTemplates
    
  self.table_name = 'channel_sms'
  EDITABLE_ATTRS = [:phone_number, { provider_config: {} }].freeze

  validates :phone_number, presence: true, uniqueness: true
  # before_save :validate_provider_config

  def name
    'Sms'
  end

  # all this should happen in provider service . but hack mode on
  def api_base_path
    'https://messaging.bandwidth.com/api/v2'
  end

  def send_message(contact_number, message)
    body = message_body(contact_number, message.content)
    body['media'] = message.attachments.map(&:download_url) if message.attachments.present?

    send_to_bandwidth(body, message)
  end

  def send_text_message(contact_number, message_content)
    body = message_body(contact_number, message_content)
    send_to_bandwidth(body)
  end

  private

  def message_body(contact_number, message_content)
    {
      'to' => contact_number,
      'from' => phone_number,
      'text' => ActionController::Base.helpers.strip_tags(message_content),
      'applicationId' => provider_config['application_id']
    }
  end

  def send_to_bandwidth(body, message = nil)
    response = HTTParty.post(
      "#{api_base_path}/users/#{provider_config['account_id']}/messages",
      basic_auth: bandwidth_auth,
      headers: { 'Content-Type' => 'application/json' },
      body: body.to_json
    )

    if response.success?
      response.parsed_response['id']
    else
      handle_error(response, message)
      nil
    end
  end

  def handle_error(response, message)
    Rails.logger.error("Error sending SMS: #{response.parsed_response['description']}")
    return if message.blank?

    # https://dev.bandwidth.com/apis/messaging-apis/messaging/#tag/Messages/operation/createMessage
    message.external_error = response.parsed_response['description']
    message.status = :failed
    message.save!
  end

  def bandwidth_auth
    { username: provider_config['api_key'], password: provider_config['api_secret'] }
  end

  # Extract later into provider Service
  # let's revisit later
  def validate_provider_config
    response = HTTParty.post(
      "#{api_base_path}/users/#{provider_config['account_id']}/messages",
      basic_auth: bandwidth_auth,
      headers: { 'Content-Type': 'application/json' }
    )
    errors.add(:provider_config, 'error setting up') unless response.success?
  end
end
