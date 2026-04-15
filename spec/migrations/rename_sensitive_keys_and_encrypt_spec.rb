require 'rails_helper'
require 'fernet'
require_relative '../../db/migrate/20260401120000_rename_sensitive_keys_and_encrypt'

RSpec.describe 'RenameSensitiveKeysAndEncrypt migration', type: :model do
  let(:encryption_key) { Base64.urlsafe_encode64(SecureRandom.random_bytes(32)) }
  let(:migration_class) { RenameSensitiveKeysAndEncrypt }
  let(:migration) { migration_class.new }

  before do
    InstallationConfig.reset_encryption_key_cache!
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('ENCRYPTION_KEY').and_return(encryption_key)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('ENCRYPTION_KEY').and_return(encryption_key)
    allow(ENV).to receive(:fetch).with('ENCRYPTION_KEY', nil).and_return(encryption_key)
  end

  after do
    InstallationConfig.reset_encryption_key_cache!
  end

  # Use migration's local model to avoid app model callbacks
  let(:config_model) { migration_class::InstallationConfig }

  describe '#up' do
    context 'key renames' do
      it 'renames all 5 keys to _SECRET equivalents' do
        renames = {
          'OPENAI_API_KEY' => 'OPENAI_API_SECRET',
          'BMS_API_KEY' => 'BMS_API_SECRET',
          'EVOLUTION_ADMIN_TOKEN' => 'EVOLUTION_ADMIN_SECRET',
          'EVOLUTION_GO_ADMIN_TOKEN' => 'EVOLUTION_GO_ADMIN_SECRET',
          'EVOLUTION_GO_INSTANCE_TOKEN' => 'EVOLUTION_GO_INSTANCE_SECRET'
        }

        renames.each do |old_name, _new_name|
          config_model.create!(name: old_name, serialized_value: { 'value' => "test-value-#{old_name}" }, locked: true)
        end

        migration.up

        renames.each do |old_name, new_name|
          expect(config_model.find_by(name: old_name)).to be_nil
          expect(config_model.find_by(name: new_name)).to be_present
        end
      end
    end

    context 'encryption' do
      it 'encrypts plaintext values for _SECRET keys' do
        config = config_model.create!(name: 'FB_APP_SECRET', serialized_value: { 'value' => 'my-secret' }, locked: true)

        migration.up

        config.reload
        raw_value = config.serialized_value['value']
        expect(raw_value).to start_with('gAAAAA')
        expect(raw_value).not_to eq('my-secret')
      end

      it 'encrypts renamed keys after rename' do
        config_model.create!(name: 'OPENAI_API_KEY', serialized_value: { 'value' => 'sk-12345' }, locked: true)

        migration.up

        renamed = config_model.find_by(name: 'OPENAI_API_SECRET')
        expect(renamed.serialized_value['value']).to start_with('gAAAAA')
      end

      it 'does not encrypt non-SECRET keys' do
        config = config_model.create!(name: 'OPENAI_API_URL', serialized_value: { 'value' => 'https://api.openai.com' }, locked: true)

        migration.up

        config.reload
        expect(config.serialized_value['value']).to eq('https://api.openai.com')
      end

      it 'skips already-encrypted values (no double encryption)' do
        encrypted = Fernet.generate(encryption_key, 'already-encrypted')
        config = config_model.create!(name: 'SLACK_CLIENT_SECRET', serialized_value: { 'value' => encrypted }, locked: true)

        migration.up

        config.reload
        expect(config.serialized_value['value']).to eq(encrypted)
      end

      it 'skips nil and blank values' do
        config_nil = config_model.create!(name: 'NIL_SECRET', serialized_value: { 'value' => nil }, locked: true)
        config_blank = config_model.create!(name: 'BLANK_SECRET', serialized_value: { 'value' => '' }, locked: true)

        migration.up

        config_nil.reload
        config_blank.reload
        expect(config_nil.serialized_value['value']).to be_nil
        expect(config_blank.serialized_value['value']).to eq('')
      end
    end

    context 'idempotency' do
      it 'can run twice without errors or data corruption' do
        config_model.create!(name: 'OPENAI_API_KEY', serialized_value: { 'value' => 'original-key' }, locked: true)
        config_model.create!(name: 'FB_APP_SECRET', serialized_value: { 'value' => 'fb-secret' }, locked: true)

        migration.up
        renamed = config_model.find_by(name: 'OPENAI_API_SECRET')
        first_encrypted_value = renamed.serialized_value['value']

        expect { migration.up }.not_to raise_error

        renamed.reload
        expect(renamed.serialized_value['value']).to eq(first_encrypted_value)
      end
    end
  end

  describe '#down' do
    it 'reverses key renames' do
      config_model.create!(name: 'OPENAI_API_SECRET', serialized_value: { 'value' => 'encrypted-val' }, locked: true)

      migration.down

      expect(config_model.find_by(name: 'OPENAI_API_SECRET')).to be_nil
      expect(config_model.find_by(name: 'OPENAI_API_KEY')).to be_present
    end

    it 'skips reverse rename if old name already exists' do
      config_model.create!(name: 'OPENAI_API_KEY', serialized_value: { 'value' => 'old' }, locked: true)
      config_model.create!(name: 'OPENAI_API_SECRET', serialized_value: { 'value' => 'new' }, locked: true)

      migration.down

      expect(config_model.where(name: 'OPENAI_API_KEY').count).to eq(1)
      expect(config_model.find_by(name: 'OPENAI_API_SECRET')).to be_present
    end
  end

  describe 'integration with InstallationConfig model' do
    it 'returns correct decrypted values through GlobalConfigService after migration' do
      config_model.create!(name: 'OPENAI_API_KEY', serialized_value: { 'value' => 'sk-test-key' }, locked: true)
      config_model.create!(name: 'FB_APP_SECRET', serialized_value: { 'value' => 'fb-secret-123' }, locked: true)

      migration.up

      # Read through the application model which has auto-decrypt
      openai = InstallationConfig.find_by(name: 'OPENAI_API_SECRET')
      expect(openai.value).to eq('sk-test-key')

      fb = InstallationConfig.find_by(name: 'FB_APP_SECRET')
      expect(fb.value).to eq('fb-secret-123')
    end
  end
end
