# frozen_string_literal: true

module ValidateRecaptcha
  ENTERPRISE_VERIFICATION_URL =
    "https://recaptchaenterprise.googleapis.com/v1/projects/#{GOOGLE_CLOUD_PROJECT_ID}/" \
    "assessments?key=#{GlobalConfig.get("ENTERPRISE_RECAPTCHA_API_KEY")}"
  RECAPTCHA_FAIL_OPEN_DEFAULTS = {
    checkout: true,
    login: false,
    signup: false,
  }.freeze
  RECAPTCHA_SCORE_LOG_PREFIX = "[recaptcha_score]"

  private_constant :ENTERPRISE_VERIFICATION_URL, :RECAPTCHA_FAIL_OPEN_DEFAULTS, :RECAPTCHA_SCORE_LOG_PREFIX

  private
    def valid_recaptcha_response_and_hostname?(site_key:)
      recaptcha_passes?(site_key:, surface: :checkout, require_hostname: true)
    end

    def valid_recaptcha_response?(site_key:, surface: :login)
      recaptcha_passes?(site_key:, surface:, require_hostname: false)
    end

    def recaptcha_passes?(site_key:, surface:, require_hostname:)
      return true if Rails.env.test?

      surface = surface.to_sym
      assessment = recaptcha_assessment(site_key:)
      threshold = recaptcha_score_threshold(surface)

      if assessment[:infra_error]
        fail_open = recaptcha_fail_open?(surface)
        log_recaptcha_score(
          surface:,
          assessment:,
          threshold:,
          hostname_ok: nil,
          decision: fail_open ? "infra_error_fail_open" : "infra_error_fail_closed"
        )

        return fail_open
      end

      hostname_ok = require_hostname ? hostname_allowed?(assessment[:hostname]) : true
      token_ok = assessment[:valid] && hostname_ok
      score_ok = threshold.nil? || (assessment[:score].present? && assessment[:score] >= threshold)
      decision = token_ok && score_ok

      log_recaptcha_score(
        surface:,
        assessment:,
        threshold:,
        hostname_ok:,
        decision: decision ? "pass" : "fail"
      )

      decision
    end

    def recaptcha_assessment(site_key:)
      verification_response = recaptcha_verification_response(site_key:)
      return { valid: false, score: nil, hostname: nil, infra_error: true } if verification_response.blank?

      {
        valid: verification_response.dig("tokenProperties", "valid") == true,
        score: parse_recaptcha_float(verification_response.dig("riskAnalysis", "score")),
        hostname: verification_response.dig("tokenProperties", "hostname"),
        infra_error: false,
      }
    end

    def recaptcha_score_threshold(surface)
      value = GlobalConfig.get("RECAPTCHA_SCORE_THRESHOLD_#{surface.to_s.upcase}")
      return nil if value.to_s.strip.blank?

      Float(value)
    rescue ArgumentError, TypeError
      Rails.logger.error("Invalid reCAPTCHA score threshold for #{surface}: #{value.inspect}")
      nil
    end

    def recaptcha_fail_open?(surface)
      value = GlobalConfig.get("RECAPTCHA_FAIL_OPEN_#{surface.to_s.upcase}")
      return RECAPTCHA_FAIL_OPEN_DEFAULTS.fetch(surface.to_sym, false) if value.to_s.strip.blank?

      ActiveModel::Type::Boolean.new.cast(value)
    end

    def hostname_allowed?(hostname)
      return true unless Rails.env.production?
      return false if hostname.blank?

      # TODO: Refactor subdomain check. Use Subdomain module if possible
      hostname == DOMAIN || hostname.end_with?(".#{ROOT_DOMAIN}") || CustomDomain.find_by_host(hostname).present?
    end

    def log_recaptcha_score(surface:, assessment:, threshold:, hostname_ok:, decision:)
      Rails.logger.info(
        [
          RECAPTCHA_SCORE_LOG_PREFIX,
          "surface=#{surface}",
          "site_key=#{surface}",
          "valid=#{assessment[:valid]}",
          "score=#{assessment[:score].nil? ? "nil" : assessment[:score]}",
          "threshold=#{threshold.nil? ? "disabled" : threshold}",
          "hostname_ok=#{hostname_ok.nil? ? "nil" : hostname_ok}",
          "decision=#{decision}",
        ].join(" ")
      )
    end

    def parse_recaptcha_float(value)
      return nil if value.nil? || value.to_s.strip.blank?

      Float(value)
    rescue ArgumentError, TypeError
      nil
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

      parsed = response.parsed_response
      if parsed.is_a?(Hash)
        parsed
      else
        Rails.logger.error("Unexpected reCAPTCHA response format: #{response.code} #{parsed.class}")
        nil
      end
    rescue StandardError => e
      Rails.logger.error("reCAPTCHA verification request failed: #{e.message}")
      nil
    end
end
