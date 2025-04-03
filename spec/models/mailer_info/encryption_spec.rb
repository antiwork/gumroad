# frozen_string_literal: true

require "spec_helper"

RSpec.describe MailerInfo::Encryption do
  describe ".encrypt" do
    it "returns nil for nil input" do
      expect(described_class.encrypt(nil)).to be_nil
    end

    it "encrypts value with current key version" do
      encrypted = described_class.encrypt("test")
      expect(encrypted).to start_with("v1:")
      expect(encrypted).not_to include("test")
      expect(encrypted.split(":").size).to eq(3)
    end

    it "converts non-string values to string" do
      encrypted = described_class.encrypt(123)
      expect(encrypted).to start_with("v1:")
      expect(described_class.decrypt(encrypted)).to eq("123")
    end
  end

  describe ".decrypt" do
    it "returns nil for nil input" do
      expect(described_class.decrypt(nil)).to be_nil
    end

    it "decrypts encrypted value" do
      value = "test_value"
      encrypted = described_class.encrypt(value)
      expect(described_class.decrypt(encrypted)).to eq(value)
    end

    it "raises error for unknown key version" do
      expect do
        described_class.decrypt("v999:abc:def")
      end.to raise_error("Unknown key version: 999")
    end

    it "raises error for invalid format" do
      expect do
        described_class.decrypt("invalid")
      end.to raise_error("Unknown key version: 0")
    end
  end

  describe "encryption keys" do
    it "uses the highest version as current key" do
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
