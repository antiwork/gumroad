# frozen_string_literal: true

require "bcrypt"

class TotpCredential < ApplicationRecord
  has_one_time_password column_name: :otp_secret

  belongs_to :user

  validates :user_id, uniqueness: true

  serialize :recovery_codes, coder: JSON

  DRIFT = 30
  RECOVERY_CODE_COUNT = 10
  RECOVERY_CODE_LENGTH = 8
  ISSUER_NAME = "Gumroad"

  def confirmed?
    confirmed_at.present?
  end

  def verify_code(code)
    authenticate_otp(code, drift: DRIFT).present?
  end

  def totp_provisioning_uri
    provisioning_uri(user.email, issuer: ISSUER_NAME)
  end

  def generate_recovery_codes
    codes = Array.new(RECOVERY_CODE_COUNT) { SecureRandom.alphanumeric(RECOVERY_CODE_LENGTH).upcase }
    hashed = codes.map { |code| BCrypt::Password.create(code) }
    update!(
      recovery_codes: hashed,
      recovery_codes_generated_at: Time.current
    )
    codes
  end

  def redeem_recovery_code(code)
    normalized = code.to_s.upcase.delete("-").strip

    with_lock do
      return false if recovery_codes.blank?

      matching_index = recovery_codes.index { |h| BCrypt::Password.new(h) == normalized }
      return false unless matching_index

      recovery_codes.delete_at(matching_index)
      update!(recovery_codes:)
    end

    true
  end
end
