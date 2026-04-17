# frozen_string_literal: true

module ValidateRecaptcha
  ENTERPRISE_VERIFICATION_URL =
    "https://recaptchaenterprise.googleapis.com/v1/projects/#{GOOGLE_CLOUD_PROJECT_ID}/" \
    "assessments?key=#{GlobalConfig.get("ENTERPRISE_RECAPTCHA_API_KEY")}"

  RECAPTCHA_SCORE_THRESHOLD = 0.5

  private_constant :ENTERPRISE_VERIFICATION_URL

  private
    def valid_recaptcha_response_and_hostname?(site_key:)
      return true if Rails.env.test?

      verification_response = recaptcha_verification_response(site_key:)
      is_valid_token = verification_response.dig("tokenProperties", "valid")
      return false if !is_valid_token
      return false if !passing_recaptcha_score?(verification_response)

      # Verify hostname only in production because the returned hostname isn't the real hostname for test keys
      if Rails.env.production?
        hostname = verification_response.dig("tokenProperties", "hostname")

        hostname == DOMAIN || hostname.end_with?(".#{ROOT_DOMAIN}") || CustomDomain.find_by_host(hostname).present?
      else
        true
      end
    end

    def valid_recaptcha_response?(site_key:)
      return true if Rails.env.test?

      verification_response = recaptcha_verification_response(site_key:)
      return false if !verification_response.dig("tokenProperties", "valid")

      passing_recaptcha_score?(verification_response)
    end

    def passing_recaptcha_score?(verification_response)
      score = verification_response.dig("riskAnalysis", "score")
      if score.nil?
        Rails.logger.warn("reCAPTCHA riskAnalysis.score missing from response, skipping score check (IP: #{request.remote_ip})")
        return true
      end

      if score < RECAPTCHA_SCORE_THRESHOLD
        Rails.logger.warn("reCAPTCHA score #{score} below threshold #{RECAPTCHA_SCORE_THRESHOLD} (IP: #{request.remote_ip})")
        return false
      end

      true
    end

    def recaptcha_verification_response(site_key:)
      response = HTTParty.post(ENTERPRISE_VERIFICATION_URL,
                               headers: { "Content-Type" => "application/json charset=utf-8" },
                               body: {
                                 event: {
                                   token: params["g-recaptcha-response"],
                                   siteKey: site_key,
                                   userAgent: request.user_agent,
                                   userIpAddress: request.remote_ip
                                 }
                               }.to_json,
                               timeout: 5)
      Rails.logger.info response

      parsed = response.parsed_response
      if parsed.is_a?(Hash)
        parsed
      else
        Rails.logger.error("Unexpected reCAPTCHA response format: #{response.code} #{parsed.class}")
        {}
      end
    rescue StandardError => e
      Rails.logger.error("reCAPTCHA verification request failed: #{e.message}")
      {}
    end
end
