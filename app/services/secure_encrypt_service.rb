# frozen_string_literal: true

class SecureEncryptService
  class Error < StandardError; end
  class MissingKeyError < Error; end
  class InvalidKeyError < Error; end

  class << self
    # Encrypts the given data.
    #
    # @param data [String] The data to encrypt.
    # @return [String] The encrypted data.
    def encrypt(data)
      encryptor.encrypt_and_sign(data)
    end

    # Decrypts the given encrypted data.
    #
    # @param encrypted_data [String] The encrypted data to decrypt.
    # @return [String, nil] The decrypted data, or nil if decryption fails.
    def decrypt(encrypted_data)
      encryptor.decrypt_and_verify(encrypted_data)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      nil
    end

    # Verifies if the user input matches the encrypted data.
    #
    # @param encrypted [String] The encrypted data.
    # @param user_input [String] The user input to compare against.
    # @return [Boolean] True if the user input matches the decrypted data, false otherwise.
    def verify(encrypted, user_input)
      decrypted_data = decrypt(encrypted)
      return false if decrypted_data.nil? || user_input.nil?

      ActiveSupport::SecurityUtils.secure_compare(decrypted_data, user_input)
    end

    private

    def encryptor
      @encryptor ||= begin
        key = GlobalConfig.get('SECURE_ENCRYPT_KEY')
        raise MissingKeyError, 'SECURE_ENCRYPT_KEY is not set.' if key.blank?
        raise InvalidKeyError, 'SECURE_ENCRYPT_KEY must be 32 bytes for aes-256-gcm.' if key.bytesize != 32

        ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm')
      end
    end
  end
end
