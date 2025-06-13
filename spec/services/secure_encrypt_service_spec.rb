# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SecureEncryptService do
  let(:key) { SecureRandom.random_bytes(32) }
  let(:data) { 'this is a secret message' }

  before do
    allow(GlobalConfig).to receive(:get).with('SECURE_ENCRYPT_KEY').and_return(key)
    # Reset memoized encryptor
    described_class.instance_variable_set(:@encryptor, nil)
  end

  describe '.encrypt' do
    it 'encrypts data' do
      encrypted_data = described_class.encrypt(data)
      expect(encrypted_data).not_to be_blank
      expect(encrypted_data).not_to eq(data)
    end
  end

  describe '.decrypt' do
    let(:encrypted_data) { described_class.encrypt(data) }

    it 'decrypts data' do
      expect(described_class.decrypt(encrypted_data)).to eq(data)
    end

    it 'returns nil for tampered data' do
      tampered_data = encrypted_data + 'tamper'
      expect(described_class.decrypt(tampered_data)).to be_nil
    end

    it 'returns nil for a different key' do
      encrypted_with_first_key = described_class.encrypt(data)

      different_key = SecureRandom.random_bytes(32)
      allow(GlobalConfig).to receive(:get).with('SECURE_ENCRYPT_KEY').and_return(different_key)
      described_class.instance_variable_set(:@encryptor, nil)

      expect(described_class.decrypt(encrypted_with_first_key)).to be_nil
    end
  end

  describe '.verify' do
    let(:encrypted_data) { described_class.encrypt(data) }

    it 'returns true for correct data' do
      expect(described_class.verify(encrypted_data, data)).to be true
    end

    it 'returns false for incorrect data' do
      expect(described_class.verify(encrypted_data, 'wrong message')).to be false
    end

    it 'returns false for tampered encrypted data' do
      tampered_data = encrypted_data + 'tamper'
      expect(described_class.verify(tampered_data, data)).to be false
    end

    it 'returns false for nil user input' do
      expect(described_class.verify(encrypted_data, nil)).to be false
    end
  end

  context 'with key configuration errors' do
    before do
      described_class.instance_variable_set(:@encryptor, nil)
    end

    it 'raises MissingKeyError if key is not set' do
      allow(GlobalConfig).to receive(:get).with('SECURE_ENCRYPT_KEY').and_return(nil)
      expect { described_class.encrypt(data) }.to raise_error(SecureEncryptService::MissingKeyError, 'SECURE_ENCRYPT_KEY is not set.')
    end

    it 'raises InvalidKeyError if key is not 32 bytes' do
      allow(GlobalConfig).to receive(:get).with('SECURE_ENCRYPT_KEY').and_return('short_key')
      expect { described_class.encrypt(data) }.to raise_error(SecureEncryptService::InvalidKeyError, 'SECURE_ENCRYPT_KEY must be 32 bytes for aes-256-gcm.')
    end
  end
end
