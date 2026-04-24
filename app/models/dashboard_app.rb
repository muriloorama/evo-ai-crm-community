# == Schema Information
#
# Table name: dashboard_apps
#
#  id               :uuid             not null, primary key
#  content          :jsonb
#  display_type     :string           default("conversation")
#  sidebar_menu     :string           default("conversations")
#  sidebar_position :string           default("after")
#  title            :string           not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :uuid             not null
#  user_id          :uuid
#
# Indexes
#
#  index_dashboard_apps_on_account_id  (account_id)
#  index_dashboard_apps_on_user_id     (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#
class DashboardApp < ApplicationRecord
  belongs_to :user
  validate :validate_content
  validates :display_type, inclusion: { in: %w[conversation sidebar] }
  validates :sidebar_menu, inclusion: { in: %w[conversations contacts pipelines campaigns automation agents channels reports settings] },
            if: -> { display_type == 'sidebar' }
  validates :sidebar_position, inclusion: { in: %w[before after] },
            if: -> { display_type == 'sidebar' }

  private

  def validate_content
    has_invalid_data = self[:content].blank? || !self[:content].is_a?(Array)
    self[:content] = [] if has_invalid_data

    content_schema = {
      'type' => 'array',
      'items' => {
        'type' => 'object',
        'required' => %w[url type],
        'properties' => {
          'type' => { 'enum': ['frame'] },
          'url' => { '$ref' => '#/definitions/saneUrl' }
        }
      },
      'definitions' => {
        'saneUrl' => { 'format' => 'uri', 'pattern' => '^https?://' }
      },
      'additionalProperties' => false,
      'minItems' => 1
    }
    errors.add(:content, ': Invalid data') unless JSONSchemer.schema(content_schema.to_json).valid?(self[:content])
  end
end
