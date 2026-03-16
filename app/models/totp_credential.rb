# frozen_string_literal: true

class TotpCredential < ApplicationRecord
  has_one_time_password column_name: :otp_secret

  belongs_to :user

  validates :user_id, uniqueness: true

  RECOVERY_CODE_COUNT = 10
  RECOVERY_CODE_LENGTH = 8
  ISSUER_NAME = "Gumroad"

  def confirmed?
    confirmed_at.present?
  end

  def verify_code(code)
    authenticate_otp(code, drift: 30).present?
  end

  def totp_provisioning_uri
    provisioning_uri(user.email, issuer: ISSUER_NAME)
  end

  def generate_recovery_codes
    codes = Array.new(RECOVERY_CODE_COUNT) { SecureRandom.alphanumeric(RECOVERY_CODE_LENGTH).upcase }
    hashed = codes.map { |code| BCrypt::Password.create(code) }
    update!(
      recovery_codes: hashed.to_json,
      recovery_codes_generated_at: Time.current
    )
    codes
  end

  def redeem_recovery_code(code)
    return false if recovery_codes.blank?

    normalized = code.to_s.upcase.gsub("-", "").strip
    hashes = JSON.parse(recovery_codes)
    matching_index = hashes.index { |h| BCrypt::Password.new(h) == normalized }
    return false unless matching_index

    hashes.delete_at(matching_index)
    update!(recovery_codes: hashes.to_json)
    true
  end

  def recovery_codes_remaining
    return 0 if recovery_codes.blank?

    JSON.parse(recovery_codes).size
  end
end
