# frozen_string_literal: true

# == Schema Information
#
# Table name: scheduled_messages
#
#  id              :uuid             not null, primary key
#  content         :text             default("")
#  error_message   :string
#  scheduled_at    :datetime         not null
#  sent_at         :datetime
#  status          :integer          default("pending"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :uuid             not null
#  conversation_id :uuid             not null
#  created_by_id   :uuid             not null
#  inbox_id        :uuid             not null
#  message_id      :uuid
#
# Indexes
#
#  index_scheduled_messages_on_account_id                  (account_id)
#  index_scheduled_messages_on_conversation_id             (conversation_id)
#  index_scheduled_messages_on_conversation_id_and_status  (conversation_id,status)
#  index_scheduled_messages_on_created_by_id               (created_by_id)
#  index_scheduled_messages_on_inbox_id                    (inbox_id)
#  index_scheduled_messages_on_status_and_scheduled_at     (status,scheduled_at)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (conversation_id => conversations.id)
#  fk_rails_...  (created_by_id => users.id)
#  fk_rails_...  (inbox_id => inboxes.id)
#
class ScheduledMessage < ApplicationRecord
  # account_id is a plain column — Account isn't a local AR model here.
  belongs_to :conversation
  belongs_to :inbox
  belongs_to :created_by, class_name: 'User'

  has_many_attached :attachments

  enum status: { pending: 0, sent: 1, cancelled: 2, failed: 3 }

  validates :account_id, presence: true
  validates :content, presence: true, if: -> { attachments.blank? }
  validates :scheduled_at, presence: true
  validate  :scheduled_at_in_future, on: :create

  scope :due, -> { pending.where('scheduled_at <= ?', Time.current) }

  def dispatch!
    return unless pending?

    message = conversation.messages.create!(
      account_id: account_id,
      inbox: inbox,
      sender: created_by,
      content: content,
      message_type: :outgoing
    )

    attachments.each do |att|
      message.attachments.create!(
        account_id: account_id,
        file_type: infer_file_type(att),
        file: att.blob
      )
    end

    update!(status: :sent, sent_at: Time.current, message_id: message.id)
  rescue StandardError => e
    update!(status: :failed, error_message: e.message.first(240))
    raise
  end

  private

  # Allow a small tolerance so a picker value of "18:35" submitted at
  # exactly 18:35:00 doesn't get rejected by a race with Time.current.
  def scheduled_at_in_future
    return if scheduled_at.blank?

    errors.add(:scheduled_at, 'deve estar no futuro') if scheduled_at < 30.seconds.ago
  end

  def infer_file_type(attachment)
    content_type = attachment.blob.content_type.to_s
    case content_type
    when /\Aimage\//  then :image
    when /\Avideo\//  then :video
    when /\Aaudio\//  then :audio
    else :file
    end
  end
end
