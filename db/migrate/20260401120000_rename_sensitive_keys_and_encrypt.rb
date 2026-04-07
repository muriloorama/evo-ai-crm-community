class RenameSensitiveKeysAndEncrypt < ActiveRecord::Migration[7.1]
  class InstallationConfig < ActiveRecord::Base
    self.table_name = 'installation_configs'
  end

  KEY_RENAMES = {
    'OPENAI_API_KEY' => 'OPENAI_API_SECRET',
    'BMS_API_KEY' => 'BMS_API_SECRET',
    'EVOLUTION_ADMIN_TOKEN' => 'EVOLUTION_ADMIN_SECRET',
    'EVOLUTION_GO_ADMIN_TOKEN' => 'EVOLUTION_GO_ADMIN_SECRET',
    'EVOLUTION_GO_INSTANCE_TOKEN' => 'EVOLUTION_GO_INSTANCE_SECRET'
  }.freeze

  def up
    require 'fernet'
    key = ENV.fetch('ENCRYPTION_KEY', nil)

    # Step 1: Rename keys
    KEY_RENAMES.each do |old_name, new_name|
      config = InstallationConfig.find_by(name: old_name)
      next unless config
      next if InstallationConfig.exists?(name: new_name)

      config.update_column(:name, new_name)
    end

    # Step 2: Encrypt all _SECRET values that are still plaintext
    return unless key.present?

    InstallationConfig.where('name LIKE ?', '%_SECRET').find_each do |config|
      val = config.serialized_value&.dig('value')
      next if val.nil? || val.to_s.blank?
      next if val.to_s.start_with?('gAAAAA')

      encrypted = Fernet.generate(key, val.to_s)
      config.update_column(:serialized_value, { 'value' => encrypted })
    end
  end

  def down
    KEY_RENAMES.each do |old_name, new_name|
      config = InstallationConfig.find_by(name: new_name)
      next unless config
      next if InstallationConfig.exists?(name: old_name)

      config.update_column(:name, old_name)
    end
    # Note: encrypted values stay encrypted — model auto-decrypts on read
  end
end
