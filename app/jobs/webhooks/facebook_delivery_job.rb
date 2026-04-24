class Webhooks::FacebookDeliveryJob < ApplicationJob
  queue_as :low

  def perform(message)
    response = ::Integrations::Facebook::MessageParser.new(message)
    channel = Channel::FacebookPage.find_by(page_id: response.recipient_id)
    return if channel.blank?

    Accountable.with_account(channel.account_id) do
      Integrations::Facebook::DeliveryStatus.new(params: response).perform
    end
  end
end
