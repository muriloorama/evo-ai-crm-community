# frozen_string_literal: true

# Drives a BroadcastCampaign through its pending recipients at
# `rate_limit_per_minute` cadence. Each invocation sends up to one minute's
# worth of messages, then reschedules itself 60 seconds later if there's
# still pending work. Campaigns are safe to cancel mid-run: a cancelled
# status short-circuits the next tick.
class BroadcastCampaigns::DispatchJob < ApplicationJob
  queue_as :low

  def perform(campaign_id)
    campaign = BroadcastCampaign.find_by(id: campaign_id)
    return unless campaign
    return unless campaign.queued? || campaign.running?

    campaign.update!(status: :running, started_at: campaign.started_at || Time.current)

    batch_size = campaign.rate_limit_per_minute.to_i
    recipients = campaign.broadcast_recipients.pending.limit(batch_size)

    if recipients.empty?
      finalize!(campaign)
      return
    end

    recipients.find_each do |recipient|
      break if campaign.reload.cancelled?

      dispatch_recipient(campaign, recipient)
    end

    # Re-enqueue one minute later if there's still work to do. Cancelled
    # campaigns skip this — they'll just sit as 'cancelled'.
    if campaign.reload.broadcast_recipients.pending.exists? && !campaign.cancelled?
      self.class.set(wait: 60.seconds).perform_later(campaign.id)
    else
      finalize!(campaign)
    end
  rescue StandardError => e
    Rails.logger.error "BroadcastCampaigns::DispatchJob failed for #{campaign_id}: #{e.message}"
    BroadcastCampaign.where(id: campaign_id).update_all(
      status: BroadcastCampaign.statuses[:failed],
      finished_at: Time.current,
      error_message: e.message.first(500)
    )
  end

  private

  def dispatch_recipient(campaign, recipient)
    contact = recipient.contact
    inbox = campaign.inbox
    channel = inbox.channel

    # Only WhatsApp Cloud has the template-send path we rely on here.
    unless channel.respond_to?(:send_template)
      recipient.update!(status: :skipped, error_message: 'Channel does not support templates')
      return
    end

    contact_inbox = ContactInbox.find_or_create_by!(
      contact: contact,
      inbox: inbox,
      source_id: contact.phone_number.to_s.delete('+').presence || contact.phone_number
    )

    conversation = Conversation.find_or_create_by!(
      account_id: campaign.account_id,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :open
    )

    params = campaign.template_params.deep_dup.merge(recipient.template_params_override || {})
    message = conversation.messages.create!(
      account_id: campaign.account_id,
      inbox: inbox,
      sender: campaign.created_by,
      content: '',
      message_type: :outgoing,
      additional_attributes: {
        'template_params' => {
          'name' => campaign.template_name,
          'language' => campaign.template_language,
          'processed_params' => params
        },
        'broadcast_campaign_id' => campaign.id
      }
    )

    recipient.update!(status: :sent, sent_at: Time.current, message_source_id: message.source_id)
    campaign.increment!(:sent_count)
  rescue StandardError => e
    Rails.logger.warn "Broadcast recipient #{recipient.id} failed: #{e.message}"
    recipient.update!(status: :failed, error_message: e.message.first(240))
    campaign.increment!(:failed_count)
  end

  def finalize!(campaign)
    return if campaign.cancelled?

    campaign.update!(status: :completed, finished_at: Time.current)
  end
end
