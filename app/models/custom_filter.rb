# == Schema Information
#
# Table name: custom_filters
#
#  id          :uuid             not null, primary key
#  filter_type :integer          default("conversation"), not null
#  name        :string           not null
#  query       :jsonb            not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  account_id  :uuid             not null
#  user_id     :uuid             not null
#
# Indexes
#
#  index_custom_filters_on_account_id  (account_id)
#  index_custom_filters_on_user_id     (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#
class CustomFilter < ApplicationRecord
  MAX_FILTER_PER_USER = 50
  belongs_to :user

  enum filter_type: { conversation: 0, contact: 1, report: 2 }
  validate :validate_number_of_filters

  def validate_number_of_filters
    return true if CustomFilter.where(user_id: user_id).size < MAX_FILTER_PER_USER

    errors.add :base, I18n.t('errors.custom_filters.number_of_records')
  end
end
