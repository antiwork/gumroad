# frozen_string_literal: true

# Force a test-safe configuration for SecureExternalId without using rspec-mocks
if defined?(SecureExternalId) && defined?(SecureExternalId::ClassMethods)
  SecureExternalId::ClassMethods.module_eval do
    def config
      {
        primary_key_version: "1",
        keys: { "1" => (ENV["MAILER_HEADERS_ENCRYPTION_KEY_V1"] || "a" * 32) }
      }
    end

    def primary_key_version
      "1"
    end

    def encryptors
      @encryptors ||= begin
        key = config[:keys][primary_key_version]
        { primary_key_version => ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm") }.with_indifferent_access
      end
    end
  end
end

