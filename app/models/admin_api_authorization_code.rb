# frozen_string_literal: true

require "base64"

class AdminApiAuthorizationCode < ApplicationRecord
  CODE_TTL = 60.seconds

  belongs_to :actor_user, class_name: "User"
  belongs_to :admin_api_token, optional: true

  validates :actor_user, :code_hash, :code_challenge, :expires_at, presence: true
  validates :code_hash, uniqueness: true

  scope :active, -> { where(used_at: nil).where("expires_at > ?", Time.current) }

  def self.create_for!(actor_user:, code_challenge:)
    plaintext_code = AdminApiToken.generate_plaintext_token
    create!(
      actor_user:,
      code_hash: hash_code(plaintext_code),
      code_challenge:,
      expires_at: CODE_TTL.from_now
    )

    plaintext_code
  end

  def self.exchange!(code:, code_verifier:)
    result = nil

    transaction do
      authorization_code = find_by(code_hash: hash_code(code))
      if authorization_code.present?
        authorization_code.lock!
        if authorization_code.exchangeable?(code_verifier)
          result = AdminApiToken.mint_with_plaintext!(
            actor_user_id: authorization_code.actor_user_id,
            expires_at: AdminApiToken.human_token_expires_at
          )
          authorization_code.update!(used_at: Time.current, admin_api_token: result.last)
        end
      end
    end

    result
  end

  def self.hash_code(code)
    AdminApiToken.hash_token(code)
  end

  def self.code_challenge_for(code_verifier)
    Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier.to_s), padding: false)
  end

  def exchangeable?(code_verifier)
    used_at.blank? && expires_at > Time.current && code_challenge_matches?(code_verifier)
  end

  private
    def code_challenge_matches?(code_verifier)
      expected_code_challenge = self.class.code_challenge_for(code_verifier)
      return false if code_challenge.bytesize != expected_code_challenge.bytesize

      ActiveSupport::SecurityUtils.secure_compare(code_challenge, expected_code_challenge)
    end
end
