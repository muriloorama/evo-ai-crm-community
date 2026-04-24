class Webhooks::TwilioEventsJob < ApplicationJob
  queue_as :low

  def perform(params = {})
    # Skip processing if Body parameter or MediaUrl0 is not present
    # This is to skip processing delivery events being delivered to this endpoint
    return if params[:Body].blank? && params[:MediaUrl0].blank?

    channel = find_twilio_channel(params)
    return if channel.blank?

    Accountable.with_account(channel.account_id) do
      ::Twilio::IncomingMessageService.new(params: params).perform
    end
  end

  private

  def find_twilio_channel(params)
    if params[:MessagingServiceSid].present?
      ::Channel::TwilioSms.find_by(messaging_service_sid: params[:MessagingServiceSid])
    elsif params[:AccountSid].present? && params[:To].present?
      ::Channel::TwilioSms.find_by(account_sid: params[:AccountSid], phone_number: params[:To])
    end
  end
end
