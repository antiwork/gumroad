# frozen_string_literal: true

require "spec_helper"

RSpec.describe SecureExternalId do
  let(:test_class) do
    Class.new do
      include SecureExternalId

      def self.name
        "TestClass"
      end

      def self.find_by(conditions)
        new if conditions[:id] == 123
      end

      def id
        123
      end
    end
  end

  let(:test_instance) { test_class.new }

  before do
    allow(GlobalConfig).to receive(:dig)
      .with(:secure_external_id, default: {})
      .and_return({
                    primary_key_version: "1",
                    keys: { "1" => "a" * 32 }
                  })
  end

  describe "#secure_external_id" do
    it "generates an encrypted token" do
      token = test_instance.secure_external_id(scope: "test")
      expect(token).to be_a(String)
      expect(token.length).to be >= 50
    end
  end

  describe ".find_by_secure_external_id" do
    it "finds record with valid token" do
      token = test_instance.secure_external_id(scope: "test")
      expect(test_class.find_by_secure_external_id(token, scope: "test")).to be_a(test_class)
    end

    it "returns nil for invalid token" do
      expect(test_class.find_by_secure_external_id("invalid", scope: "test")).to be_nil
    end

    it "returns nil for wrong scope" do
      token = test_instance.secure_external_id(scope: "test")
      expect(test_class.find_by_secure_external_id(token, scope: "wrong")).to be_nil
    end

    it "checks for expired token" do
      expires_at = 1.hour.from_now
      token = test_instance.secure_external_id(scope: "test", expires_at: expires_at)

      travel_to 45.minutes.from_now do
        expect(test_class.find_by_secure_external_id(token, scope: "test")).to be_a(test_class)
      end

      travel_to 2.hours.from_now do
        expect(test_class.find_by_secure_external_id(token, scope: "test")).to be_nil # expired
      end
    end


    it "returns nil for non-string input" do
      expect(test_class.find_by_secure_external_id(123, scope: "test")).to be_nil
    end

    it "returns nil for invalid base64" do
      expect(test_class.find_by_secure_external_id("invalid base64!", scope: "test")).to be_nil
    end

    it "returns nil for wrong model name" do
      other_class = Class.new do
        include SecureExternalId

        def self.name
          "OtherClass"
        end

        def id
          123
        end
      end

      token = test_instance.secure_external_id(scope: "test")
      expect(other_class.find_by_secure_external_id(token, scope: "test")).to be_nil
    end

    it "supports key rotation" do
      token_v1 = test_instance.secure_external_id(scope: "test")

      allow(GlobalConfig).to receive(:dig)
        .with(:secure_external_id, default: {})
        .and_return({
                      primary_key_version: "2",
                      keys: {
                        "1" => "a" * 32,
                        "2" => "b" * 32
                      }
                    })

      expect(test_class.find_by_secure_external_id(token_v1, scope: "test")).to be_a(test_class)

      token_v2 = test_instance.secure_external_id(scope: "test")
      expect(test_class.find_by_secure_external_id(token_v2, scope: "test")).to be_a(test_class)
    end
  end

  describe "configuration validation" do
    it "raises error when configuration is blank" do
      allow(GlobalConfig).to receive(:dig)
        .with(:secure_external_id, default: {})
        .and_return({})

      expect do
        test_instance.secure_external_id(scope: "test")
      end.to raise_error(SecureExternalId::Error, "SecureExternalId configuration is missing")
    end

    it "raises error when primary_key_version is missing" do
      allow(GlobalConfig).to receive(:dig)
        .with(:secure_external_id, default: {})
        .and_return({
                      keys: { "1" => "a" * 32 }
                    })

      expect do
        test_instance.secure_external_id(scope: "test")
      end.to raise_error(SecureExternalId::Error, "primary_key_version is required in SecureExternalId config")
    end

    it "raises error when primary_key_version is blank" do
      allow(GlobalConfig).to receive(:dig)
        .with(:secure_external_id, default: {})
        .and_return({
                      primary_key_version: "",
                      keys: { "1" => "a" * 32 }
                    })

      expect do
        test_instance.secure_external_id(scope: "test")
      end.to raise_error(SecureExternalId::Error, "primary_key_version is required in SecureExternalId config")
    end

    it "raises error when keys are missing" do
      allow(GlobalConfig).to receive(:dig)
        .with(:secure_external_id, default: {})
        .and_return({
                      primary_key_version: "1"
                    })

      expect do
        test_instance.secure_external_id(scope: "test")
      end.to raise_error(SecureExternalId::Error, "keys are required in SecureExternalId config")
    end

    it "raises error when keys are blank" do
      allow(GlobalConfig).to receive(:dig)
        .with(:secure_external_id, default: {})
        .and_return({
                      primary_key_version: "1",
                      keys: {}
                    })

      expect do
        test_instance.secure_external_id(scope: "test")
      end.to raise_error(SecureExternalId::Error, "keys are required in SecureExternalId config")
    end

    it "raises error when primary key version is not found in keys" do
      allow(GlobalConfig).to receive(:dig)
        .with(:secure_external_id, default: {})
        .and_return({
                      primary_key_version: "2",
                      keys: { "1" => "a" * 32 }
                    })

      expect do
        test_instance.secure_external_id(scope: "test")
      end.to raise_error(SecureExternalId::Error, "Primary key version '2' not found in keys")
    end

    it "raises error when key is not exactly 32 bytes" do
      allow(GlobalConfig).to receive(:dig)
        .with(:secure_external_id, default: {})
        .and_return({
                      primary_key_version: "1",
                      keys: { "1" => "short_key" }
                    })

      expect do
        test_instance.secure_external_id(scope: "test")
      end.to raise_error(SecureExternalId::Error, "Key for version '1' must be exactly 32 bytes for aes-256-gcm")
    end

    it "raises error when any key in rotation is not exactly 32 bytes" do
      allow(GlobalConfig).to receive(:dig)
        .with(:secure_external_id, default: {})
        .and_return({
                      primary_key_version: "1",
                      keys: {
                        "1" => "a" * 32,
                        "2" => "too_short"
                      }
                    })

      expect do
        test_instance.secure_external_id(scope: "test")
      end.to raise_error(SecureExternalId::Error, "Key for version '2' must be exactly 32 bytes for aes-256-gcm")
    end

    it "passes validation with proper configuration" do
      allow(GlobalConfig).to receive(:dig)
        .with(:secure_external_id, default: {})
        .and_return({
                      primary_key_version: "1",
                      keys: {
                        "1" => "a" * 32,
                        "2" => "b" * 32
                      }
                    })

      expect do
        test_instance.secure_external_id(scope: "test")
      end.not_to raise_error
    end
  end
end
