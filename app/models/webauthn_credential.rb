# frozen_string_literal: true

require "digest"

class WebauthnCredential < ApplicationRecord
  include ExternalId

  MAX_PER_USER = 10
  MAX_PER_USER_ERROR = :too_many_passkeys
  MAX_PER_USER_ERROR_MESSAGE = "You can add up to #{MAX_PER_USER} passkeys."
  MAX_NICKNAME_LENGTH = 100
  MAX_WEBAUTHN_ID_LENGTH = 1_364

  AAGUID_PROVIDER_NAMES = {
    "fbfc3007-154e-4ecc-8c0b-6e020557d7bd" => "iCloud Keychain",
    "bada5566-a7aa-401f-bd96-45619a55120d" => "1Password",
    "ea9b8d66-4d01-1d21-3ce4-b6b48cb575d4" => "Google Password Manager",
    "adce0002-35bc-c60a-648b-0b25f1f05503" => "Chrome on Mac",
    "08987058-cadc-4b81-b6e1-30de50dcbe96" => "Windows Hello",
    "9ddd1817-af5a-4672-a2b9-3e3dd95000a9" => "Windows Hello",
    "6028b017-b1d4-4c02-b4b3-afcdafc96bb2" => "Windows Hello",
    "d548826e-79b4-db40-a3d8-11116f7e8349" => "Bitwarden",
    "531126d6-e717-415c-9320-3d9aa6981239" => "Dashlane",
    "fdb141b2-5d84-443e-8a35-4698c205a502" => "KeePassXC",
  }.freeze

  belongs_to :user

  def self.provider_name_for_aaguid(aaguid)
    AAGUID_PROVIDER_NAMES[aaguid]
  end

  before_validation :set_webauthn_id_sha256
  before_validation :normalize_nickname
  before_validation :set_default_nickname, on: :create

  validates :webauthn_id, presence: true, length: { maximum: MAX_WEBAUTHN_ID_LENGTH }
  validates :webauthn_id_sha256, presence: true
  validates :public_key, presence: true
  validates :sign_count, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :nickname, presence: true, length: { maximum: MAX_NICKNAME_LENGTH }
  validate :webauthn_id_must_be_unique
  validate :user_credential_limit, on: :create

  private
    def set_webauthn_id_sha256
      self.webauthn_id_sha256 = Digest::SHA256.hexdigest(webauthn_id) if webauthn_id.present?
    end

    def set_default_nickname
      self.nickname = nickname.presence || "Passkey #{next_nickname_number}"
    end

    def normalize_nickname
      self.nickname = nickname.to_s.strip if nickname.present?
    end

    def next_nickname_number
      return 1 if user.blank?

      user.webauthn_credentials.count + 1
    end

    def webauthn_id_must_be_unique
      return if webauthn_id_sha256.blank?

      matching_credentials = self.class.where(webauthn_id_sha256:)
      matching_credentials = matching_credentials.where.not(id:) if persisted?
      errors.add(:webauthn_id, "has already been taken") if matching_credentials.exists?
    end

    def user_credential_limit
      return if user.blank?
      return if user.webauthn_credentials.count < MAX_PER_USER

      errors.add(:base, MAX_PER_USER_ERROR, message: MAX_PER_USER_ERROR_MESSAGE)
    end
end
