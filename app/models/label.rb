# == Schema Information
#
# Table name: labels
#
#  id              :uuid             not null, primary key
#  color           :string           default("#1f93ff"), not null
#  description     :text
#  show_on_sidebar :boolean
#  title           :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :uuid             not null
#
# Indexes
#
#  index_labels_on_account_id  (account_id)
#  index_labels_on_title       (title) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#
class Label < ApplicationRecord
  include RegexHelper
  include Events::Types

  validates :title,
            presence: { message: I18n.t('errors.validations.presence') },
            format: { with: UNICODE_CHARACTER_NUMBER_SPACE_HYPHEN_UNDERSCORE, allow_blank: true },
            uniqueness: true

  after_create_commit :dispatch_create_event
  after_update_commit :update_associated_models, :dispatch_update_event
  after_destroy_commit :dispatch_destroy_event
  default_scope { order(:title) }

  before_validation do
    next unless attribute_present?('title')
    
    if title.is_a?(String)
      stripped = title.strip
      self.title = stripped.present? ? stripped.downcase : nil
    end
  end

  def conversations
    Conversation.tagged_with(title)
  end

  def messages
    Message.where(conversation_id: conversations.pluck(:id))
  end

  def reporting_events
    ReportingEvent.where(conversation_id: conversations.pluck(:id))
  end

  private

  def update_associated_models
    return unless title_previously_changed?

    Labels::UpdateJob.perform_later(title, title_previously_was)
  end

  def dispatch_create_event
    Rails.configuration.dispatcher.dispatch(LABEL_CREATED, Time.zone.now, label: self)
  end

  def dispatch_update_event
    Rails.configuration.dispatcher.dispatch(LABEL_UPDATED, Time.zone.now, label: self, saved_changes: saved_changes)
  end

  def dispatch_destroy_event
    Rails.configuration.dispatcher.dispatch(LABEL_DELETED, Time.zone.now, label: self)
  end
end
