# frozen_string_literal: true

# Runs every minute via sidekiq-cron. Finds all ScheduledMessage rows whose
# scheduled_at has elapsed and dispatches them by creating actual outgoing
# Messages. Failures mark the row as failed but don't block the rest of
# the batch.
class ScheduledMessages::DispatchJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    ScheduledMessage.due.find_each do |scheduled|
      scheduled.dispatch!
    rescue StandardError => e
      Rails.logger.error "ScheduledMessages::DispatchJob failed for #{scheduled.id}: #{e.message}"
    end
  end
end
