## Cron job: scans follow_up_executions that reached their next_attempt_at
# and fans out one ExecuteJob per execution. Runs every minute via
# sidekiq-cron (see config/schedule.yml).
#
# Fan-out (vs processing inline) keeps one slow AI call / send failure
# from blocking the rest of the queue.
class FollowUps::SchedulerJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH_LIMIT = 200

  def perform
    FollowUpExecution
      .runnable
      .order(next_attempt_at: :asc)
      .limit(BATCH_LIMIT)
      .pluck(:id)
      .each { |execution_id| FollowUps::ExecuteJob.perform_later(execution_id) }
  end
end
