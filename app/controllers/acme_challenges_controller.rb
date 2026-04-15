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

    content = $redis.get(RedisKey.acme_challenge(token))

    if content.present?
      render plain: content
    else
      head :not_found
    end
  end

  private
    def mask_token(token)
      return "nil" if token.blank?
      return token if token.length <= 4

      "#{token[0..1]}...#{token[-2..]}"
    end

    def valid_token?(token)
      token.present? && token.length <= MAX_TOKEN_LENGTH && token.match?(VALID_TOKEN_PATTERN)
    end
end
