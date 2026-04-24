# == Schema Information
#
# Table name: canned_responses
#
#  id         :uuid             not null, primary key
#  content    :text
#  short_code :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  account_id :uuid             not null
#
# Indexes
#
#  index_canned_responses_on_account_id  (account_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#
class CannedResponse < ApplicationRecord
  validates :content, presence: true
  validates :short_code, presence: true
  validates :short_code, uniqueness: true

  # Adicionar associação polimórfica
  has_many :attachments, as: :attachable, dependent: :destroy

  # Validar que o número de attachments não excede o máximo permitido
  validates :attachments, length: { maximum: 15, message: 'exceeded maximum allowed attachments' }

  scope :order_by_search, lambda { |search|
    short_code_starts_with = sanitize_sql_array(['WHEN short_code ILIKE ? THEN 1', "#{search}%"])
    short_code_like = sanitize_sql_array(['WHEN short_code ILIKE ? THEN 0.5', "%#{search}%"])
    content_like = sanitize_sql_array(['WHEN content ILIKE ? THEN 0.2', "%#{search}%"])

    order_clause = "CASE #{short_code_starts_with} #{short_code_like} #{content_like} ELSE 0 END"

    order(Arel.sql(order_clause) => :desc)
  }

  def as_json(options = {})
    super(options).merge(
      attachments: attachments.map(&:push_event_data)
    )
  end
end
