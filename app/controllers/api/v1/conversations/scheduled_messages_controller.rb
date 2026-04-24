# frozen_string_literal: true

# CRUD endpoints for ScheduledMessage rows attached to a conversation.
# index   GET    /api/v1/conversations/:conversation_id/scheduled_messages
# create  POST   /api/v1/conversations/:conversation_id/scheduled_messages
# destroy DELETE /api/v1/conversations/:conversation_id/scheduled_messages/:id
class Api::V1::Conversations::ScheduledMessagesController < Api::V1::Conversations::BaseController
  def index
    rows = @conversation.scheduled_messages.order(scheduled_at: :asc)
    success_response(
      data: rows.map { |row| serialize(row) },
      message: 'Scheduled messages retrieved'
    )
  end

  def create
    scheduled = @conversation.scheduled_messages.new(
      account_id: @conversation.account_id,
      inbox: @conversation.inbox,
      created_by: Current.user,
      content: params[:content].to_s,
      scheduled_at: params[:scheduled_at]
    )

    Array(params[:attachments]).each do |file|
      scheduled.attachments.attach(file)
    end

    if scheduled.save
      success_response(
        data: serialize(scheduled),
        message: 'Message scheduled',
        status: :created
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        scheduled.errors.full_messages.join(', '),
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    scheduled = @conversation.scheduled_messages.find(params[:id])
    scheduled.update!(status: :cancelled) if scheduled.pending?

    success_response(data: serialize(scheduled), message: 'Scheduled message cancelled')
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Not found', status: :not_found)
  end

  private

  def serialize(row)
    {
      id: row.id,
      content: row.content,
      status: row.status,
      scheduled_at: row.scheduled_at,
      sent_at: row.sent_at,
      error_message: row.error_message,
      attachment_count: row.attachments.count,
      created_by: { id: row.created_by_id, name: row.created_by&.name }
    }
  end
end
