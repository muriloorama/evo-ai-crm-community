require 'rails_helper'

RSpec.describe InstallationConfig, type: :model do
  let(:encryption_key) { Base64.urlsafe_encode64(SecureRandom.random_bytes(32)) }

  before do
    described_class.reset_encryption_key_cache!
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('ENCRYPTION_KEY').and_return(encryption_key)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('ENCRYPTION_KEY').and_return(encryption_key)
  end

  after do
    described_class.reset_encryption_key_cache!
  end

  describe '#sensitive?' do
    it 'returns true for keys ending in _SECRET' do
      config = described_class.new(name: 'SMTP_PASSWORD_SECRET')
      expect(config.sensitive?).to be true
    end

    it 'returns false for keys not ending in _SECRET' do
      config = described_class.new(name: 'SMTP_ADDRESS')
      expect(config.sensitive?).to be false
    end

    it 'returns false for keys partially matching _SECRET' do
      config = described_class.new(name: 'SECRET_KEY_BASE')
      expect(config.sensitive?).to be false
    end
  end

  describe 'encryption on save' do
    it 'encrypts the value for _SECRET keys' do
      config = described_class.create!(name: 'API_KEY_SECRET', value: 'my-secret-api-key')
      raw = described_class.find(config.id).read_attribute(:serialized_value)
      expect(raw['value']).to start_with('gAAAAA')
      expect(raw['value']).not_to eq('my-secret-api-key')
    end

    it 'stores plaintext for non-_SECRET keys' do
      config = described_class.create!(name: 'APP_NAME', value: 'MyApp')
      raw = described_class.find(config.id).read_attribute(:serialized_value)
      expect(raw['value']).to eq('MyApp')
    end

    it 'does not double-encrypt already-encrypted values' do
      config = described_class.create!(name: 'TOKEN_SECRET', value: 'original-secret')
      raw_first = described_class.find(config.id).read_attribute(:serialized_value)['value']

      config.reload
      config.save!
      raw_second = described_class.find(config.id).read_attribute(:serialized_value)['value']

      expect(raw_second).to eq(raw_first)
    end

    it 'handles nil values without encrypting' do
      config = described_class.create!(name: 'EMPTY_SECRET', value: nil)
      raw = described_class.find(config.id).read_attribute(:serialized_value)
      expect(raw['value']).to be_nil
    end

    it 'handles blank string values without encrypting' do
      config = described_class.create!(name: 'BLANK_SECRET', value: '')
      raw = described_class.find(config.id).read_attribute(:serialized_value)
      expect(raw['value']).to eq('')
    end
  end

  describe '#value (decryption)' do
    it 'returns decrypted plaintext for encrypted _SECRET keys' do
      config = described_class.create!(name: 'DB_PASSWORD_SECRET', value: 'super-secret-password')
      config.reload
      expect(config.value).to eq('super-secret-password')
    end

    it 'returns plaintext as-is for non-_SECRET keys' do
      config = described_class.create!(name: 'SITE_NAME', value: 'Evolution')
      config.reload
      expect(config.value).to eq('Evolution')
    end

    it 'round-trips encrypted values correctly' do
      original = 'my-api-key-12345'
      config = described_class.create!(name: 'STRIPE_SECRET', value: original)
      config.reload
      expect(config.value).to eq(original)
    end

    it 'handles nil values for sensitive keys' do
      config = described_class.create!(name: 'NIL_SECRET', value: nil)
      config.reload
      expect(config.value).to be_nil
    end

    it 'preserves boolean false values for non-sensitive keys' do
      config = described_class.create!(name: 'FEATURE_FLAG', value: false)
      config.reload
      expect(config.value).to eq(false)
    end
  end

  describe '#masked_value' do
    it 'returns masked value for sensitive keys' do
      config = described_class.create!(name: 'API_TOKEN_SECRET', value: 'my-long-secret-value')
      config.reload
      expect(config.masked_value).to eq('••••••••alue')
    end

    it 'returns full value for non-sensitive keys' do
      config = described_class.create!(name: 'SITE_URL', value: 'https://example.com')
      config.reload
      expect(config.masked_value).to eq('https://example.com')
    end

    it 'returns nil if value is blank for sensitive keys' do
      config = described_class.create!(name: 'EMPTY_VAL_SECRET', value: nil)
      config.reload
      expect(config.masked_value).to be_nil
    end

    it 'returns nil if value is empty string for sensitive keys' do
      config = described_class.create!(name: 'BLANK_VAL_SECRET', value: '')
      config.reload
      expect(config.masked_value).to be_nil
    end
  end

  describe 'raw DB column verification' do
    it 'stores encrypted data in serialized_value column for sensitive keys' do
      plaintext = 'this-should-be-encrypted'
      config = described_class.create!(name: 'WEBHOOK_SECRET', value: plaintext)

      raw_value = ActiveRecord::Base.connection.execute(
        "SELECT serialized_value FROM installation_configs WHERE id = '#{config.id}'"
      ).first['serialized_value']

      parsed = JSON.parse(raw_value)
      expect(parsed['value']).to start_with('gAAAAA')
      expect(parsed['value']).not_to include(plaintext)
    end
  end

  describe '.encryption_key' do
    it 'returns the ENCRYPTION_KEY env var when present' do
      expect(described_class.encryption_key).to eq(encryption_key)
    end

    context 'when ENCRYPTION_KEY is not set' do
      before do
        described_class.reset_encryption_key_cache!
        allow(ENV).to receive(:[]).with('ENCRYPTION_KEY').and_return(nil)
      end

      it 'derives a deterministic key from SECRET_KEY_BASE' do
        first = described_class.encryption_key
        described_class.reset_encryption_key_cache!
        second = described_class.encryption_key

        expect(first).to be_present
        expect(first).to eq(second)
      end

      it 'derives a valid Fernet key usable for encrypt/decrypt' do
        key = described_class.encryption_key
        token = Fernet.generate(key, 'roundtrip')
        verifier = Fernet.verifier(key, token, enforce_ttl: false)
        expect(verifier.valid?).to be true
        expect(verifier.message).to eq('roundtrip')
      end

      it 'raises when SECRET_KEY_BASE is also absent' do
        allow(ENV).to receive(:[]).with('SECRET_KEY_BASE').and_return(nil)
        allow(Rails.application).to receive(:secret_key_base).and_return(nil)
        expect { described_class.encryption_key }.to raise_error(RuntimeError, /ENCRYPTION_KEY/)
      end
    end
  end

  describe 'non-sensitive key with fernet-like value' do
    it 'does not attempt decryption for non-sensitive keys even if value looks like a fernet token' do
      fernet_like = 'gAAAAABfake_token_value_here'
      config = described_class.create!(name: 'SOME_SETTING', value: fernet_like)
      config.reload
      expect(config.value).to eq(fernet_like)
    end
  end
end
