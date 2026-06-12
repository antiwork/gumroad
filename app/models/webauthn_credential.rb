# frozen_string_literal: true

require "digest"

class WebauthnCredential < ApplicationRecord
  include ExternalId

  MAX_PER_USER = 10
  MAX_PER_USER_ERROR = :too_many_passkeys
  MAX_PER_USER_ERROR_MESSAGE = "You can add up to #{MAX_PER_USER} passkeys."
  MAX_NICKNAME_LENGTH = 100
  MAX_WEBAUTHN_ID_LENGTH = 1_364

  belongs_to :user

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
