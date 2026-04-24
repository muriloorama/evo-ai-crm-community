# == Schema Information
#
# Table name: notification_settings
#
#  id          :uuid             not null, primary key
#  email_flags :integer          default(0), not null
#  push_flags  :integer          default(0), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  account_id  :uuid             not null
#  user_id     :uuid
#
# Indexes
#
#  by_user                                    (user_id) UNIQUE
#  index_notification_settings_on_account_id  (account_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#
class NotificationSetting < ApplicationRecord
  # used for single column multi flags
  include FlagShihTzu

  belongs_to :user

  DEFAULT_QUERY_SETTING = {
    flag_query_mode: :bit_operator,
    check_for_column: false
  }.freeze

  EMAIL_NOTIFICATION_FLAGS = ::Notification::NOTIFICATION_TYPES.transform_keys { |key| "email_#{key}".to_sym }.invert.freeze
  PUSH_NOTIFICATION_FLAGS = ::Notification::NOTIFICATION_TYPES.transform_keys { |key| "push_#{key}".to_sym }.invert.freeze

  has_flags EMAIL_NOTIFICATION_FLAGS.merge(column: 'email_flags').merge(DEFAULT_QUERY_SETTING)
  has_flags PUSH_NOTIFICATION_FLAGS.merge(column: 'push_flags').merge(DEFAULT_QUERY_SETTING)
end
