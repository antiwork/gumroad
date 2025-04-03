# frozen_string_literal: true

module ValidateRecaptcha
  ENTERPRISE_VERIFICATION_URL =
    "https://recaptchaenterprise.googleapis.com/v1/projects/#{GOOGLE_CLOUD_PROJECT_ID}/" \
    "assessments?key=#{GlobalConfig.get("ENTERPRISE_RECAPTCHA_API_KEY")}"

  private_constant :ENTERPRISE_VERIFICATION_URL

  private
    def valid_recaptcha_response_and_hostname?(site_key:)
      return true if Rails.env.test?

      verification_response = recaptcha_verification_response(site_key:)
      is_valid_token = verification_response.dig("tokenProperties", "valid")

      # Verify hostname only in production because the returned hostname isn't the real hostname for test keys
      if Rails.env.production?
        hostname = verification_response.dig("tokenProperties", "hostname")

        is_valid_token && (
          # TODO: Refactor subdomain check. Use Subdomain module if possible
          hostname == DOMAIN || hostname.end_with?(".#{ROOT_DOMAIN}") || CustomDomain.find_by_host(hostname).present?)
      else
        is_valid_token
      end
    end

    def valid_recaptcha_response?(site_key:)
      return true if Rails.env.test?

      verification_response = recaptcha_verification_response(site_key:)
      verification_response.dig("tokenProperties", "valid")
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
      response
    end
end
