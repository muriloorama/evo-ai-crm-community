class EventDispatcherJob < ApplicationJob
  queue_as :critical

  def perform(event_name, timestamp, data)
    # Runs in Sidekiq, so Current.account_id is nil. Most listeners create
    # ReportingEvents / Messages / Notifications that require account_id.
    # Extract it from common event payload shapes and scope the dispatch.
    account_id = extract_account_id(data)

    if account_id
      Accountable.with_account(account_id) do
        Rails.configuration.dispatcher.async_dispatcher.publish_event(event_name, timestamp, data)
      end
    else
      Rails.configuration.dispatcher.async_dispatcher.publish_event(event_name, timestamp, data)
    end
  end

  private

  def extract_account_id(data)
    return nil unless data.is_a?(Hash)

    [:conversation, :message, :contact, :user, :account_id].each do |key|
      val = data[key]
      next if val.nil?
      return val if key == :account_id
      return val.account_id if val.respond_to?(:account_id) && val.account_id.present?
    end
    nil
  rescue StandardError
    nil
  end
end
