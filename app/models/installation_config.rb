# == Schema Information
#
# Table name: installation_configs
#
#  id               :uuid             not null, primary key
#  locked           :boolean          default(TRUE), not null
#  name             :string           not null
#  serialized_value :jsonb            not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Indexes
#
#  index_installation_configs_on_name                 (name) UNIQUE
#  index_installation_configs_on_name_and_created_at  (name,created_at) UNIQUE
#
require 'fernet'

class InstallationConfig < ApplicationRecord
  # https://stackoverflow.com/questions/72970170/upgrading-to-rails-6-1-6-1-causes-psychdisallowedclass-tried-to-load-unspecif
  # https://discuss.rubyonrails.org/t/cve-2022-32224-possible-rce-escalation-bug-with-serialized-columns-in-active-record/81017
  # FIX ME : fixes breakage of installation config. we need to migrate.
  # Fix configuration in application.rb
  # JSONB column provides native JSON serialization - no need for explicit serialize

  before_validation :set_lock
  before_save :encrypt_sensitive_value
  validates :name, presence: true

  # TODO: Get rid of default scope
  # https://stackoverflow.com/a/1834250/939299
  default_scope { order(created_at: :desc) }
  scope :editable, -> { where(locked: false) }

  after_commit :clear_cache

  ENCRYPTION_KEY_DERIVATION_SALT = 'installation_config_encryption_v1'

  def self.encryption_key
    @encryption_key ||= resolve_encryption_key
  end

  def self.reset_encryption_key_cache!
    @encryption_key = nil
  end

  def self.resolve_encryption_key
    ENV['ENCRYPTION_KEY'].presence || derive_encryption_key_from_secret_key_base
  end

  def self.derive_encryption_key_from_secret_key_base
    secret = ENV['SECRET_KEY_BASE'].presence ||
             (defined?(Rails) && Rails.application&.secret_key_base.presence)
    raise 'ENCRYPTION_KEY or SECRET_KEY_BASE must be set' if secret.blank?

    key_material = ActiveSupport::KeyGenerator.new(secret).generate_key(
      ENCRYPTION_KEY_DERIVATION_SALT, 32
    )
    Base64.urlsafe_encode64(key_material)
  end

  def sensitive?
    name.to_s.end_with?('_SECRET')
  end

  def value
    # Handle JSONB native serialization - no YAML issues with JSONB
    return {}.with_indifferent_access if new_record? && serialized_value.blank?

    # Handle different data types in serialized_value
    case serialized_value
    when Hash
      # Use key? check instead of || to preserve false boolean values
      if serialized_value.key?('value')
        val = serialized_value['value']
        # Return empty hash only if value is nil, preserve false/true booleans
        val.nil? ? nil : decrypt_if_sensitive(val)
      else
        {}.with_indifferent_access
      end
    when String
      # Legacy YAML string data - deserialize it using unsafe_load for ActiveSupport classes
      begin
        yaml_data = YAML.unsafe_load(serialized_value)
        if yaml_data.is_a?(Hash) && yaml_data.key?('value')
          yaml_data['value']
        else
          yaml_data
        end
      rescue Psych::Exception => e
        Rails.logger.warn "InstallationConfig#value: Failed to parse YAML for #{name}: #{e.message}"
        serialized_value
      end
    else
      {}.with_indifferent_access
    end
  end

  def value=(value_to_assigned)
    self.serialized_value = {
      value: value_to_assigned
    }.with_indifferent_access
  end

  def masked_value
    return nil if value.blank?
    return value unless sensitive?

    "••••••••#{value.to_s.last(4)}"
  end

  private

  def fernet_token?(val)
    val.is_a?(String) && val.start_with?('gAAAAA')
  end

  def decrypt_if_sensitive(val)
    return val unless sensitive? && fernet_token?(val)

    verifier = Fernet.verifier(self.class.encryption_key, val, enforce_ttl: false)
    verifier.valid? ? verifier.message : val
  rescue StandardError => e
    Rails.logger.error "InstallationConfig#decrypt: Failed to decrypt #{name}: #{e.message}"
    val
  end

  def encrypt_sensitive_value
    return unless sensitive?
    return unless serialized_value.is_a?(Hash) && serialized_value.key?('value')

    val = serialized_value['value']
    return if val.nil? || val.to_s.blank?
    return if fernet_token?(val)

    self.serialized_value = serialized_value.merge('value' => Fernet.generate(self.class.encryption_key, val.to_s))
  rescue StandardError => e
    Rails.logger.error "InstallationConfig#encrypt: Failed to encrypt #{name}: #{e.message}"
    raise
  end

  def set_lock
    self.locked = true if locked.nil?
  end

  def clear_cache
    GlobalConfig.clear_cache
  end
end
