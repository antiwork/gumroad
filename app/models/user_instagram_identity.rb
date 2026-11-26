# frozen_string_literal: true

class UserInstagramIdentity < ApplicationRecord
  # Meta's long-lived tokens last 60 days and can be renewed once they are a day old.
  TOKEN_REFRESH_WINDOW = 7.days

  belongs_to :user

  validates :instagram_user_id, presence: true
  validates :user_id, uniqueness: true

  def access_token
    return if encrypted_access_token.blank?

    self.class.token_encryptor.decrypt_and_verify(encrypted_access_token)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    nil
  end

  def access_token=(token)
    self.encrypted_access_token = token.presence && self.class.token_encryptor.encrypt_and_sign(token)
  end

  def can_publish?
    access_token.present? && access_token_expires_at&.future?
  end

  def token_due_for_refresh?
    can_publish? && access_token_expires_at < TOKEN_REFRESH_WINDOW.from_now
  end

  def self.token_encryptor
    @token_encryptor ||= ActiveSupport::MessageEncryptor.new(
      Rails.application.key_generator.generate_key("user_instagram_identity/access_token", ActiveSupport::MessageEncryptor.key_len)
    )
  end
end
