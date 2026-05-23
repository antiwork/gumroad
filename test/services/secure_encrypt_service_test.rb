# frozen_string_literal: true

require "test_helper"

class SecureEncryptServiceTest < ActiveSupport::TestCase
  self.described_class = SecureEncryptService



  context_ SecureEncryptService do
    let(:key) { SecureRandom.random_bytes(32) }
    let(:text) { "this is a secret message" }

    before do
      allow(GlobalConfig).to receive(:get).with("SECURE_ENCRYPT_KEY").and_return(key)
      # Reset memoized encryptor
      described_class.instance_variable_set(:@encryptor, nil)
    end

  context_ ".encrypt" do
  test "encrypts text" do
        encrypted_text = described_class.encrypt(text)
        expect(encrypted_text).not_to be_blank
        expect(encrypted_text).not_to eq(text)
      end
    end

  context_ ".decrypt" do
      let(:encrypted_text) { described_class.encrypt(text) }

  test "decrypts text" do
        expect(described_class.decrypt(encrypted_text)).to eq(text)
      end

  test "returns nil for tampered text" do
        tampered_text = encrypted_text + "tamper"
        expect(described_class.decrypt(tampered_text)).to be_nil
      end

  test "returns nil for a different key" do
        encrypted_with_first_key = described_class.encrypt(text)

        different_key = SecureRandom.random_bytes(32)
        allow(GlobalConfig).to receive(:get).with("SECURE_ENCRYPT_KEY").and_return(different_key)
        described_class.instance_variable_set(:@encryptor, nil)

        expect(described_class.decrypt(encrypted_with_first_key)).to be_nil
      end
    end

  context_ ".verify" do
      let(:encrypted_text) { described_class.encrypt(text) }

  test "returns true for correct text" do
        expect(described_class.verify(encrypted_text, text)).to be true
      end

  test "returns false for incorrect text" do
        expect(described_class.verify(encrypted_text, "wrong message")).to be false
      end

  test "returns false for tampered encrypted text" do
        tampered_text = encrypted_text + "tamper"
        expect(described_class.verify(tampered_text, text)).to be false
      end

  test "returns false for nil user input" do
        expect(described_class.verify(encrypted_text, nil)).to be false
      end
    end

  context_ "with key configuration errors" do
      before do
        described_class.instance_variable_set(:@encryptor, nil)
      end

  test "raises MissingKeyError if key is not set" do
        allow(GlobalConfig).to receive(:get).with("SECURE_ENCRYPT_KEY").and_return(nil)
        expect { described_class.encrypt(text) }.to raise_error(SecureEncryptService::MissingKeyError, "SECURE_ENCRYPT_KEY is not set.")
      end

  test "raises InvalidKeyError if key is not 32 bytes" do
        allow(GlobalConfig).to receive(:get).with("SECURE_ENCRYPT_KEY").and_return("short_key")
        expect { described_class.encrypt(text) }.to raise_error(SecureEncryptService::InvalidKeyError, "SECURE_ENCRYPT_KEY must be 32 bytes for aes-256-gcm.")
      end
    end
  end
end
