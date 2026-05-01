# frozen_string_literal: true

# CRUD + lifecycle endpoints for WhatsApp broadcast campaigns.
# POST /broadcast_campaigns                       create draft
# POST /broadcast_campaigns/:id/add_recipients    bulk-add contacts
# POST /broadcast_campaigns/:id/enqueue           mark as queued, kick off job
# POST /broadcast_campaigns/:id/cancel            stop a running campaign
# GET  /broadcast_campaigns                        list
# GET  /broadcast_campaigns/:id                    details + progress
class Api::V1::BroadcastCampaignsController < Api::V1::BaseController
  before_action :fetch_campaign, only: %i[show add_recipients enqueue cancel]
  # FeatureGate — broadcast campaigns require the `features.broadcast`
  # toggle. Listing/viewing remains available so the UI can render history
  # even when the feature was just turned off.
  before_action -> { ensure_feature!('features.broadcast') }, only: %i[create add_recipients enqueue]

  def index
    campaigns = BroadcastCampaign.where(account_id: Current.account_id).order(created_at: :desc)
    success_response(data: campaigns.map { |c| serialize(c) })
  end

  def show
    success_response(data: serialize(@campaign, include_recipients: true))
  end

  def create
    campaign = BroadcastCampaign.new(
      account_id: Current.account_id,
      inbox_id: params[:inbox_id],
      created_by: Current.user,
      name: params[:name],
      template_name: params[:template_name],
      template_language: params[:template_language].presence || 'pt_BR',
      template_params: params[:template_params]&.permit!.to_h || {},
      rate_limit_per_minute: params[:rate_limit_per_minute] || 60,
      scheduled_at: params[:scheduled_at]
    )

    if campaign.save
      success_response(data: serialize(campaign), status: :created, message: 'Campaign created')
    else
      error_response(ApiErrorCodes::VALIDATION_ERROR, campaign.errors.full_messages.join(', '),
                     status: :unprocessable_entity)
    end
  end

  def add_recipients
    contact_ids = Array(params[:contact_ids]).compact.uniq
    return error_response(ApiErrorCodes::VALIDATION_ERROR, 'No contact_ids provided',
                          status: :unprocessable_entity) if contact_ids.empty?

    ActiveRecord::Base.transaction do
      contact_ids.each do |contact_id|
        @campaign.broadcast_recipients.find_or_create_by!(contact_id: contact_id)
      end
      @campaign.update!(total_recipients: @campaign.broadcast_recipients.count)
    end

    success_response(data: serialize(@campaign), message: "#{contact_ids.size} recipients added")
  end

  def enqueue
    return error_response(ApiErrorCodes::OPERATION_NOT_ALLOWED,
                           "Only draft campaigns can be enqueued",
                           status: :unprocessable_entity) unless @campaign.draft?
    return error_response(ApiErrorCodes::VALIDATION_ERROR,
                           "Add recipients before enqueuing",
                           status: :unprocessable_entity) if @campaign.broadcast_recipients.empty?

    @campaign.update!(status: :queued)
    BroadcastCampaigns::DispatchJob.perform_later(@campaign.id)

    success_response(data: serialize(@campaign), message: 'Campaign enqueued')
  end

  def cancel
    return error_response(ApiErrorCodes::OPERATION_NOT_ALLOWED,
                           "Campaign already finalised",
                           status: :unprocessable_entity) if @campaign.completed? || @campaign.cancelled?

    @campaign.update!(status: :cancelled, finished_at: Time.current)
    success_response(data: serialize(@campaign), message: 'Campaign cancelled')
  end

  private

  def fetch_campaign
    @campaign = BroadcastCampaign.where(account_id: Current.account_id).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Campaign not found', status: :not_found)
  end

  def serialize(campaign, include_recipients: false)
    result = {
      id: campaign.id,
      name: campaign.name,
      status: campaign.status,
      template_name: campaign.template_name,
      template_language: campaign.template_language,
      inbox_id: campaign.inbox_id,
      scheduled_at: campaign.scheduled_at,
      started_at: campaign.started_at,
      finished_at: campaign.finished_at,
      total_recipients: campaign.total_recipients,
      sent_count: campaign.sent_count,
      failed_count: campaign.failed_count,
      rate_limit_per_minute: campaign.rate_limit_per_minute,
      progress_percent: campaign.progress_percent,
      error_message: campaign.error_message,
      created_at: campaign.created_at
    }

    if include_recipients
      result[:recipients] = campaign.broadcast_recipients.includes(:contact).limit(500).map do |r|
        {
          id: r.id,
          contact_id: r.contact_id,
          contact_name: r.contact&.name,
          phone_number: r.contact&.phone_number,
          status: r.status,
          sent_at: r.sent_at,
          error_message: r.error_message
        }
      end
    end

    result
  end
end
