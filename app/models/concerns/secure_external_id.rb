# frozen_string_literal: true

# A concern to generate and resolve secure, expiring, encrypted, URL-safe tokens
# that represent a model instance. It supports key rotation.
#
# Configuration:
# This module requires configuration in your config/credentials.yml.enc or environment variables via GlobalConfig.
# The configuration should contain a primary key version and a list of encryption keys for generating secure tokens.
# You must provide a primary key version and a list of keys.
# The primary key is used for encrypting new tokens. All keys are available for decryption.
#
# @example in `config/credentials.yml.enc`
#
#   secure_external_id:
#     primary_key_version: '1' # This MUST be a string
#     keys:
#       '1': 'a_very_secure_secret_key_for_v1' # 32 bytes for aes-256-gcm
#       '2': 'a_different_secure_key_for_v2' # 32 bytes for aes-256-gcm
#
module SecureExternalId
  extend ActiveSupport::Concern

  class Error < StandardError; end
  class InvalidToken < Error; end
  class KeyNotFound < Error; end

  # Generates a secure, URL-safe token for the model instance.
  #
  # @param scope [String] The scope of the token.
  # @param expires_at [Time, nil] The optional expiration timestamp for the token.
  # @return [String] The versioned, encrypted, URL-safe token.
  def secure_external_id(scope:, expires_at: nil)
    self.class.encrypt_id(id, scope: scope, expires_at: expires_at)
  end

  module ClassMethods
    # Finds a record by its secure external ID.
    #
    # @param token [String] The token to decrypt and use for finding the record.
    # @param scope [String] The expected scope of the token.
    # @return [ActiveRecord::Base, nil] The model instance if the token is valid, not expired,
    #   for the correct model, and has the correct scope; otherwise nil.
    def find_by_secure_external_id(token, scope:)
      record_id = decrypt_id(token, scope: scope)
      find_by(id: record_id) if record_id
    end

    # Encrypts a record's ID into a secure, URL-safe token.
    # This is a low-level method; prefer using the instance method `secure_external_id`.
    #
    # @param id [String, Integer] The ID of the record.
    # @param scope [String] The scope of the token.
    # @param expires_at [Time, nil] The optional expiration timestamp for the token.
    # @return [String] The versioned, encrypted, URL-safe token.
    def encrypt_id(id, scope:, expires_at: nil)
      version = primary_key_version
      encryptor = encryptors[version]
      raise KeyNotFound, "Primary key version '#{version}' not found" unless encryptor

      inner_payload = {
        model: name,
        id: id,
        exp: expires_at&.to_i,
        scp: scope
      }

      encrypted_data = encryptor.encrypt_and_sign(inner_payload.to_json)

      outer_payload = {
        v: version,
        d: encrypted_data
      }

      Base64.urlsafe_encode64(outer_payload.to_json, padding: false)
    end

    # Decrypts a token to retrieve a record's ID if the token is valid.
    # This is a low-level method; prefer using `find_by_secure_external_id`.
    #
    # @param token [String] The token to decrypt.
    # @param scope [String] The expected scope of the token.
    # @return [String, Integer, nil] The ID if the token is valid; otherwise nil.
    def decrypt_id(token, scope:)
      return nil unless token.is_a?(String)

      decoded_json = Base64.urlsafe_decode64(token)
      outer_payload = JSON.parse(decoded_json, symbolize_names: true)

      version = outer_payload[:v]
      encrypted_data = outer_payload[:d]
      return nil if version.blank? || encrypted_data.blank?

      encryptor = encryptors[version]
      return nil unless encryptor # Invalid version

      decrypted_json = encryptor.decrypt_and_verify(encrypted_data)
      inner_payload = JSON.parse(decrypted_json, symbolize_names: true)

      return nil if inner_payload[:model] != name
      return nil if inner_payload[:scp] != scope
      return nil if inner_payload[:exp] && Time.current.to_i > inner_payload[:exp]

      inner_payload[:id]
    rescue JSON::ParserError, ArgumentError, ActiveSupport::MessageEncryptor::InvalidMessage => e
      Rails.logger.error "SecureExternalId decryption failed: #{e.class}"
      nil
    end

    private
      def config
        @config ||= begin
          raw_config = GlobalConfig.dig(:secure_external_id, default: {})
          validate_config!(raw_config)
          raw_config
        end
      end

      def validate_config!(config)
        raise Error, "SecureExternalId configuration is missing" if config.blank?
        raise Error, "primary_key_version is required in SecureExternalId config" if config[:primary_key_version].blank?
        raise Error, "keys are required in SecureExternalId config" if config[:keys].blank?

        keys_hash = config[:keys].with_indifferent_access
        raise Error, "Primary key version '#{config[:primary_key_version]}' not found in keys" unless keys_hash.key?(config[:primary_key_version])

        keys_hash.each do |version, key|
          raise Error, "Key for version '#{version}' must be exactly 32 bytes for aes-256-gcm" unless key.bytesize == 32
        end
      end

      def primary_key_version
        config[:primary_key_version]
      end

      def encryptors
        @encryptors ||= (config[:keys] || {}).transform_values do |key|
          ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
        end.with_indifferent_access
      end
  end
end
