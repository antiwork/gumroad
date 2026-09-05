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

  # Single-use transition from pending to confirmed, protected by a row lock so two
  # concurrent confirms carrying the same code cannot both complete (gp#2402). Returns
  # the freshly minted recovery codes on success, nil if the credential is already
  # confirmed (replayed/redundant), or false if the code is invalid.
  def confirm(code)
    with_lock do
      return nil if confirmed?
      return false unless verify_code(code)

      update!(confirmed_at: Time.current)
      generate_recovery_codes
    end
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
