class Webhooks::TwilioDeliveryStatusJob < ApplicationJob
  queue_as :low

  def perform(params = {})
    channel = find_twilio_channel(params)
    return if channel.blank?

    Accountable.with_account(channel.account_id) do
      ::Twilio::DeliveryStatusService.new(params: params).perform
    end
  end

  private

  def find_twilio_channel(params)
    if params[:MessagingServiceSid].present?
      ::Channel::TwilioSms.find_by(messaging_service_sid: params[:MessagingServiceSid])
    elsif params[:AccountSid].present? && params[:From].present?
      ::Channel::TwilioSms.find_by(account_sid: params[:AccountSid], phone_number: params[:From])
    end
  end
end
