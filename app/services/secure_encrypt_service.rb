# frozen_string_literal: true

class SecureEncryptService
  class Error < StandardError; end
  class MissingKeyError < Error; end
  class InvalidKeyError < Error; end

  class << self
    # Encrypts the given text.
    #
    # @param text [String] The text to encrypt.
    # @return [String] The encrypted text.
    def encrypt(text)
      encryptor.encrypt_and_sign(text)
    end

    # Decrypts the given encrypted text.
    #
    # @param encrypted_text [String] The encrypted text to decrypt.
    # @return [String, nil] The decrypted text, or nil if decryption fails.
    def decrypt(encrypted_text)
      encryptor.decrypt_and_verify(encrypted_text)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      nil
    end

    # Verifies if the user input matches the encrypted text.
    #
    # @param encrypted [String] The encrypted text.
    # @param text [String] The user input to compare against.
    # @return [Boolean] True if the user input matches the decrypted text, false otherwise.
    def verify(encrypted, text)
      decrypted_text = decrypt(encrypted)
      return false if decrypted_text.nil? || text.nil?

      ActiveSupport::SecurityUtils.secure_compare(decrypted_text, text)
    end

    private
      def encryptor
        @encryptor ||= begin
          key = GlobalConfig.get("SECURE_ENCRYPT_KEY")
          raise MissingKeyError, "SECURE_ENCRYPT_KEY is not set." if key.blank?
          raise InvalidKeyError, "SECURE_ENCRYPT_KEY must be 32 bytes for aes-256-gcm." if key.bytesize != 32

          ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
        end
      end
  end
end
