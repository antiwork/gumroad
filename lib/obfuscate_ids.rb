# frozen_string_literal: true

require "openssl"
require "base64"

module ObfuscateIds
  CIPHER_KEY = GlobalConfig.get("OBFUSCATE_IDS_CIPHER_KEY")
  NUMERIC_CIPHER_KEY = GlobalConfig.get("OBFUSCATE_IDS_NUMERIC_CIPHER_KEY").to_i

  def self.encrypt(id)
    c = cipher.encrypt
    c.key = Digest::SHA256.digest(CIPHER_KEY)
    Base64.urlsafe_encode64(c.update(id.to_s) + c.final)
  end

  def self.cipher
    OpenSSL::Cipher.new("aes-256-cbc")
  end

  def self.decrypt(id)
    c = cipher.decrypt
    c.key = Digest::SHA256.digest(CIPHER_KEY)
    begin
      (c.update(Base64.urlsafe_decode64(id.to_s)) + c.final).to_i
    rescue ArgumentError, OpenSSL::Cipher::CipherError => e
      Rails.logger.warn "could not decrypt #{id}: #{e.message} #{e.backtrace}"
      nil
    end
  end

  # Public: Encrypt id using NUMERIC_CIPHER_KEY
  #
  # id - id to be encrypted
  #
  # Examples
  #
  #   encrypt_numeric(1)
  #   # => 302841629
  #
  # Returns encrypted numeric id
  def self.encrypt_numeric(id)
    extended_and_reversed_binary_id = id.to_s(2).rjust(30, "0")
    binary_id = xor(extended_and_reversed_binary_id, NUMERIC_CIPHER_KEY.to_s(2), 30).reverse
    binary_id.to_i(2)
  end

  # Public: Decrypt id using NUMERIC_CIPHER_KEY
  #
  # id - id to be decrypted
  #
  # Examples
  #
  #   decrypt_numeric(302841629)
  #   # => 1
  #
  # Returns decrypted numeric id
  def self.decrypt_numeric(encrypted_id)
    binary_id = encrypted_id.to_s(2).rjust(30, "0").reverse
    extended_binary_id = xor(binary_id, NUMERIC_CIPHER_KEY.to_s(2), 30)
    extended_binary_id.to_i(2)
  end

  # Private: Bitwise xor of two binary strings of length n
  #
  # binary_string_a, binary_string_b - strings to be xor'd
  # n - number of bits in strings
  #
  # Example
  #
  #   xor("1000", "0011", 4)
  #   # => "1011"
  #
  # Returns string that is xor of inputs
  def self.xor(binary_string_a, binary_string_b, n)
    ((0..n - 1).map { |index| (binary_string_a[index].to_i ^ binary_string_b[index].to_i) }).join("")
  end

  private_class_method :xor
end
