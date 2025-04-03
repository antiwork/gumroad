# frozen_string_literal: true

module MailerInfo::Encryption
  extend self
  include Kernel

  def encrypt(value)
    return value if value.nil?
    cipher = OpenSSL::Cipher.new("aes-256-cbc")
    cipher.encrypt
    key_version = current_key_version
    cipher.key = derive_key(key_version)
    iv = cipher.random_iv

    encrypted = cipher.update(value.to_s) + cipher.final
    "v#{key_version}:#{Base64.strict_encode64(iv)}:#{Base64.strict_encode64(encrypted)}"
  end

  def decrypt(encrypted_value)
    return encrypted_value if encrypted_value.nil?
    version, iv, encrypted = encrypted_value.split(":")
    key_version = version.delete_prefix("v").to_i

    cipher = OpenSSL::Cipher.new("aes-256-cbc")
    cipher.decrypt
    cipher.key = derive_key(key_version)
    cipher.iv = Base64.strict_decode64(iv)

    cipher.update(Base64.strict_decode64(encrypted)) + cipher.final
  end

  private
    def derive_key(version)
      key = encryption_keys.fetch(version) { Kernel.raise "Unknown key version: #{version}" }
      Digest::SHA256.digest(key)
    end

    def encryption_keys
      {
        1 => GlobalConfig.get("MAILER_HEADERS_ENCRYPTION_KEY_V1"),
        # Add new keys as needed, old keys must be kept for old emails
        # 2 => GlobalConfig.get("MAILER_HEADERS_ENCRYPTION_KEY_V2"),
      }
    end

    def current_key_version
      encryption_keys.keys.max
    end
end
