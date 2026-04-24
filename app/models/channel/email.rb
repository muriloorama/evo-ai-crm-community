# == Schema Information
#
# Table name: channel_email
#
#  id                        :uuid             not null, primary key
#  email                     :string           not null
#  email_signature           :text
#  forward_to_email          :string           not null
#  imap_address              :string           default("")
#  imap_enable_ssl           :boolean          default(TRUE)
#  imap_enabled              :boolean          default(FALSE)
#  imap_login                :string           default("")
#  imap_password             :string           default("")
#  imap_port                 :integer          default(0)
#  provider                  :string
#  provider_config           :jsonb
#  smtp_address              :string           default("")
#  smtp_authentication       :string           default("login")
#  smtp_domain               :string           default("")
#  smtp_enable_ssl_tls       :boolean          default(FALSE)
#  smtp_enable_starttls_auto :boolean          default(TRUE)
#  smtp_enabled              :boolean          default(FALSE)
#  smtp_login                :string           default("")
#  smtp_openssl_verify_mode  :string           default("none")
#  smtp_password             :string           default("")
#  smtp_port                 :integer          default(0)
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  account_id                :uuid             not null
#
# Indexes
#
#  index_channel_email_on_account_id        (account_id)
#  index_channel_email_on_email             (email) UNIQUE
#  index_channel_email_on_forward_to_email  (forward_to_email) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#

class Channel::Email < ApplicationRecord
  include Channelable
  include ChannelMessageTemplates
  include Reauthorizable

  AUTHORIZATION_ERROR_THRESHOLD = 10

  self.table_name = 'channel_email'
  EDITABLE_ATTRS = [:email, :imap_enabled, :imap_login, :imap_password, :imap_address, :imap_port, :imap_enable_ssl,
                    :smtp_enabled, :smtp_login, :smtp_password, :smtp_address, :smtp_port, :smtp_domain, :smtp_enable_starttls_auto,
                    :smtp_enable_ssl_tls, :smtp_openssl_verify_mode, :smtp_authentication, :provider, :email_signature].freeze

  validates :email, uniqueness: true
  validates :forward_to_email, uniqueness: true

  before_validation :ensure_forward_to_email, on: :create
  before_destroy :disable_push_if_enabled, prepend: true

  def name
    'Email'
  end

  def microsoft?
    provider == 'microsoft'
  end

  def google?
    provider == 'google'
  end

  def legacy_google?
    imap_enabled && imap_address == 'imap.gmail.com'
  end

  def push_enabled?
    google? && provider_config['push_enabled'] == true
  end

  def use_push_notifications?
    push_enabled?
  end

  def enable_push!
    Rails.logger.info "[GMAIL_PUSH] enable_push! called for #{email} - google?: #{google?}"
    return unless google?

    if push_enabled?
      Rails.logger.info "[GMAIL_PUSH] Push already enabled for #{email}, skipping"
      return
    end

    # Enable push in provider_config
    current_config = provider_config || {}
    Rails.logger.info "[GMAIL_PUSH] Current provider_config before merge: #{current_config.inspect}"
    updated_config = current_config.merge('push_enabled' => true)
    Rails.logger.info "[GMAIL_PUSH] Updated provider_config after merge: #{updated_config.inspect}"

    update!(
      provider_config: updated_config
    )

    Rails.logger.info "[GMAIL_PUSH] provider_config saved - push_enabled: #{reload.provider_config['push_enabled']}"

    # Setup Gmail watch
    gmail_service = Gmail::ApiService.new(channel: self)
    gmail_service.watch_mailbox

    Rails.logger.info "[GMAIL_PUSH] Push notifications enabled for #{email}"
  end

  def disable_push!
    return unless google?

    # Stop Gmail watch
    gmail_service = Gmail::ApiService.new(channel: self)
    gmail_service.stop_watch

    # Disable push in provider_config
    update!(
      provider_config: (provider_config || {}).merge('push_enabled' => false)
    )

    Rails.logger.info "[GMAIL_PUSH] Push notifications disabled for #{email}"
  rescue StandardError => e
    Rails.logger.error "[GMAIL_PUSH] Error disabling push: #{e.message}"
  end

  private

  def ensure_forward_to_email
    domain = ENV.fetch('MAILER_INBOUND_EMAIL_DOMAIN', ENV.fetch('FRONTEND_URL', 'example.com').gsub(%r{https?://}, ''))
    self.forward_to_email ||= "#{SecureRandom.hex}@#{domain}"
  end

  def disable_push_if_enabled
    return unless google?
    return unless push_enabled?

    disable_push!
  rescue StandardError => e
    Rails.logger.error "[GMAIL_PUSH] Error disabling push before destroy: #{e.message}"
    # Don't raise - allow destroy to proceed even if push disable fails
  end
end
