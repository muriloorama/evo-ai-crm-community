# Background sync of Meta Ads spend.
#
# - With no args: iterates all active MetaAdAccounts (used by sidekiq-cron).
# - With an id: syncs that one account (used by the "Sincronizar agora" button).
class MetaAds::SyncJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(meta_account_id = nil)
    if meta_account_id
      account = MetaAdAccount.unscoped.find(meta_account_id)
      MetaAds::SyncService.new(account).call
    else
      MetaAdAccount.unscoped.active.find_each do |account|
        next if account.token_expired?
        MetaAds::SyncService.new(account).call
      end
    end
  end
end
