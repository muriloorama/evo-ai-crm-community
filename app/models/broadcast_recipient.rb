# frozen_string_literal: true

# == Schema Information
#
# Table name: broadcast_recipients
#
#  id                       :uuid             not null, primary key
#  error_message            :text
#  sent_at                  :datetime
#  status                   :integer          default("pending"), not null
#  template_params_override :jsonb
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  broadcast_campaign_id    :uuid             not null
#  contact_id               :uuid             not null
#  message_source_id        :string
#
# Indexes
#
#  idx_broadcast_recipients_campaign         (broadcast_campaign_id)
#  idx_broadcast_recipients_status           (broadcast_campaign_id,status)
#  index_broadcast_recipients_on_contact_id  (contact_id)
#
# Foreign Keys
#
#  fk_rails_...  (broadcast_campaign_id => broadcast_campaigns.id)
#  fk_rails_...  (contact_id => contacts.id)
#
class BroadcastRecipient < ApplicationRecord
  belongs_to :broadcast_campaign
  belongs_to :contact

  enum status: { pending: 0, sent: 1, failed: 2, skipped: 3 }
end
