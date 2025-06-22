# frozen_string_literal: true

require "spec_helper"

RSpec.describe SecureEncryptService do
  let(:key) { SecureRandom.random_bytes(32) }
  let(:text) { "this is a secret message" }

  before do
    allow(GlobalConfig).to receive(:get).with("SECURE_ENCRYPT_KEY").and_return(key)
    # Reset memoized encryptor
    described_class.instance_variable_set(:@encryptor, nil)
  end

  describe ".encrypt" do
    it "encrypts text" do
      encrypted_text = described_class.encrypt(text)
      expect(encrypted_text).not_to be_blank
      expect(encrypted_text).not_to eq(text)
    end
  end

  describe ".decrypt" do
    let(:encrypted_text) { described_class.encrypt(text) }

    it "decrypts text" do
      expect(described_class.decrypt(encrypted_text)).to eq(text)
    end

    it "returns nil for tampered text" do
      tampered_text = encrypted_text + "tamper"
      expect(described_class.decrypt(tampered_text)).to be_nil
    end

    it "returns nil for a different key" do
      encrypted_with_first_key = described_class.encrypt(text)

      different_key = SecureRandom.random_bytes(32)
      allow(GlobalConfig).to receive(:get).with("SECURE_ENCRYPT_KEY").and_return(different_key)
      described_class.instance_variable_set(:@encryptor, nil)

      expect(described_class.decrypt(encrypted_with_first_key)).to be_nil
    end
  end

  describe ".verify" do
    let(:encrypted_text) { described_class.encrypt(text) }

    it "returns true for correct text" do
      expect(described_class.verify(encrypted_text, text)).to be true
    end

    it "returns false for incorrect text" do
      expect(described_class.verify(encrypted_text, "wrong message")).to be false
    end

    it "returns false for tampered encrypted text" do
      tampered_text = encrypted_text + "tamper"
      expect(described_class.verify(tampered_text, text)).to be false
    end

    it "returns false for nil user input" do
      expect(described_class.verify(encrypted_text, nil)).to be false
    end
  end

  context "with key configuration errors" do
    before do
      described_class.instance_variable_set(:@encryptor, nil)
    end

    it "raises MissingKeyError if key is not set" do
      allow(GlobalConfig).to receive(:get).with("SECURE_ENCRYPT_KEY").and_return(nil)
      expect { described_class.encrypt(text) }.to raise_error(SecureEncryptService::MissingKeyError, "SECURE_ENCRYPT_KEY is not set.")
    end

    it "raises InvalidKeyError if key is not 32 bytes" do
      allow(GlobalConfig).to receive(:get).with("SECURE_ENCRYPT_KEY").and_return("short_key")
      expect { described_class.encrypt(text) }.to raise_error(SecureEncryptService::InvalidKeyError, "SECURE_ENCRYPT_KEY must be 32 bytes for aes-256-gcm.")
    end
  end
end
