# frozen_string_literal: true

class AcmeChallengesController < ApplicationController
  MAX_TOKEN_LENGTH = 64
  VALID_TOKEN_PATTERN = /\A[A-Za-z0-9_-]+\z/

  def show
    token = params[:token]
    Rails.logger.info "[ACME Challenge] Verification request received for token: #{mask_token(token)}, host: #{request.host}"

    unless valid_token?(token)
      head :bad_request
      return
    end

    content = acme_challenge_content(token)

    if content.present?
      render plain: content
    else
      head :not_found
    end
  end

  private
    # A stalled read is "no challenge staged" (404), the same as an expired token, rather than
    # failing the certificate-issuance check.
    def acme_challenge_content(token)
      $redis.get(RedisKey.acme_challenge(token))
    rescue *REDIS_TRANSPORT_ERRORS
      nil
    end

    def mask_token(token)
      return "nil" if token.blank?
      return token if token.length <= 4

      "#{token[0..1]}...#{token[-2..]}"
    end

    def valid_token?(token)
      token.present? && token.length <= MAX_TOKEN_LENGTH && token.match?(VALID_TOKEN_PATTERN)
    end
end
