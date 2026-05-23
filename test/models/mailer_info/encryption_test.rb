# frozen_string_literal: true

require "test_helper"

class MailerInfoEncryptionTest < ActiveSupport::TestCase
  self.described_class = MailerInfo::Encryption



  context_ MailerInfo::Encryption do
  context_ ".encrypt" do
  test "returns nil for nil input" do
        expect(described_class.encrypt(nil)).to be_nil
      end

  test "encrypts value with current key version" do
        encrypted = described_class.encrypt("test")
        expect(encrypted).to start_with("v1:")
        expect(encrypted).not_to include("test")
        expect(encrypted.split(":").size).to eq(3)
      end

  test "converts non-string values to string" do
        encrypted = described_class.encrypt(123)
        expect(encrypted).to start_with("v1:")
        expect(described_class.decrypt(encrypted)).to eq("123")
      end
    end

  context_ ".decrypt" do
  test "returns nil for nil input" do
        expect(described_class.decrypt(nil)).to be_nil
      end

  test "decrypts encrypted value" do
        value = "test_value"
        encrypted = described_class.encrypt(value)
        expect(described_class.decrypt(encrypted)).to eq(value)
      end

  test "raises error for unknown key version" do
        expect do
          described_class.decrypt("v999:abc:def")
        end.to raise_error("Unknown key version: 999")
      end

  test "raises error for invalid format" do
        expect do
          described_class.decrypt("invalid")
        end.to raise_error("Unknown key version: 0")
      end
    end

  context_ "encryption keys" do
  test "uses the highest version as current key" do
        allow(described_class).to receive(:encryption_keys).and_return({
                                                                         1 => "key1",
                                                                         2 => "key2",
                                                                         3 => "key3"
                                                                       })

        encrypted = described_class.encrypt("test")
        expect(encrypted).to start_with("v3:")
      end
    end
  end
end
