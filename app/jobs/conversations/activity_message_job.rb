class Conversations::ActivityMessageJob < ApplicationJob
  queue_as :high

  def perform(conversation, message_params)
    # Runs in Sidekiq with no request context, so Current.account_id is nil
    # and the Accountable before_validation callback can't auto-fill the
    # new message's account_id. Scope to the conversation's account so the
    # NOT NULL constraint is satisfied.
    Accountable.with_account(conversation.account_id) do
      conversation.messages.create!(message_params)
    end
  end
end
