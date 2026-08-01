# frozen_string_literal: true

module ValidateRecaptcha
  # Buyer/user-facing message for a failed CAPTCHA verification. Names the most common
  # self-fixable causes (ad blockers / privacy extensions blocking the reCAPTCHA script)
  # so people aren't stranded with "try again" that never works — the only way they used
  # to discover the cause was emailing support (gumroad-private#927). Kept in sync with
  # RECAPTCHA_UNAVAILABLE_MESSAGE in app/javascript/components/useRecaptcha.tsx.
  CAPTCHA_FAILURE_MESSAGE = "Sorry, we could not verify the CAPTCHA. This can be caused by ad blockers, " \
    "privacy extensions, or VPNs — try disabling them for this page or using a " \
    "private/incognito window, then try again."

  # Score-based keys never show a challenge, so a genuine, correctly-hosted token can be refused
  # purely on risk score — ~755 checkouts a day hit that with the message above, which is false
  # there (gumroad-private#1590).
  CAPTCHA_LOW_SCORE_MESSAGE = "Sorry, we could not complete this purchase — our fraud check " \
    "scored this browser session as risky. Nothing is wrong with your payment method. Try " \
    "again on a different network (turn off a VPN or switch off Wi-Fi to mobile data), or " \
    "from a different browser or device. If it keeps happening, contact support and we will " \
    "help you finish your purchase."

  ENTERPRISE_VERIFICATION_URL =
    "https://recaptchaenterprise.googleapis.com/v1/projects/#{GOOGLE_CLOUD_PROJECT_ID}/" \
    "assessments?key=#{GlobalConfig.get("ENTERPRISE_RECAPTCHA_API_KEY")}"
  # `follow` fails open for the same reason checkout does: when Google's
  # verification call errors we have no evidence about the visitor either way, and
  # a Google outage would otherwise break the subscribe form for every seller who
  # has not been reviewed yet — which is every new account. Nothing else catches
  # abuse during such a window today, so the tradeoff is deliberate and narrow:
  # the outage has to be happening while the ring is running, the oversized-token
  # lane below stops a visitor from inducing one on demand, and every decision is
  # logged as `infra_error_fail_open` so the window is visible after the fact.
  # Override per environment with RECAPTCHA_FAIL_OPEN_FOLLOW=false.
  RECAPTCHA_FAIL_OPEN_DEFAULTS = {
    checkout: true,
    checkout_score: true,
    checkout_score_trusted: true,
    follow: true,
    login: false,
  }.freeze
  # Default score thresholds used when the per-surface Redis key is unset.
  # Surfaces not listed here default to nil (no score gating — token validity
  # alone). The score-based checkout key returns a score for ~every valid token,
  # so it gates at 0.5 out of the box; trusted buyers (see CheckoutRecaptcha) get
  # a more lenient 0.3 bar. Override at runtime per surface by setting
  # RedisKey.recaptcha_score_threshold(surface), e.g.
  # $redis.set(RedisKey.recaptcha_score_threshold(:checkout_score), "0.4").
  RECAPTCHA_SCORE_THRESHOLD_DEFAULTS = {
    checkout_score: 0.5,
    checkout_score_trusted: 0.3,
  }.freeze
  RECAPTCHA_SCORE_LOG_PREFIX = "[recaptcha_score]"

  # A real reCAPTCHA token is on the order of 1-2 KB. Anything an order of
  # magnitude past that was not minted by Google, and forwarding it upstream
  # risks the verification request failing for size or timeout reasons — which
  # lands on the infrastructure-error path, and that path fails OPEN for checkout
  # and follow. So an absurdly long token counts as an invalid token (fail
  # closed) and is never sent to Google, which closes the one lane where a
  # visitor could deliberately induce a fail-open decision on every request.
  MAX_RECAPTCHA_TOKEN_LENGTH = 32_768

  private_constant :ENTERPRISE_VERIFICATION_URL, :RECAPTCHA_FAIL_OPEN_DEFAULTS, :RECAPTCHA_SCORE_THRESHOLD_DEFAULTS, :RECAPTCHA_SCORE_LOG_PREFIX, :MAX_RECAPTCHA_TOKEN_LENGTH

  private
    def valid_recaptcha_response_and_hostname?(site_key:, surface: :checkout)
      recaptcha_passes?(site_key:, surface:, require_hostname: true)
    end

    def valid_recaptcha_response?(site_key:, surface: :login)
      recaptcha_passes?(site_key:, surface:, require_hostname: false)
    end

    def recaptcha_passes?(site_key:, surface:, require_hostname:)
      return true if Rails.env.test?

      surface = surface.to_sym
      assessment = recaptcha_assessment(site_key:)
      threshold = recaptcha_score_threshold(surface)
      @recaptcha_failed_on_score_only = false

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
      scored = assessment[:score].present?
      score_ok = threshold.nil? || (scored && assessment[:score] >= threshold)
      decision = token_ok && score_ok

      # An absent score also fails `score_ok`, but "scored as risky" would be equally false
      # there, so nil-score failures keep the generic copy.
      @recaptcha_failed_on_score_only = token_ok && scored && !score_ok

      log_recaptcha_score(
        surface:,
        assessment:,
        threshold:,
        hostname_ok:,
        decision: decision ? "pass" : "fail"
      )

      decision
    end

    def recaptcha_failure_message
      @recaptcha_failed_on_score_only ? CAPTCHA_LOW_SCORE_MESSAGE : CAPTCHA_FAILURE_MESSAGE
    end

    # A score-only refusal is the only CAPTCHA failure with recourse: the token was minted by
    # Google for a host we allow, so the visitor can still be asked to prove humanity against a
    # key that renders a challenge (see OrdersController). Every other failure — invalid token,
    # wrong hostname, no score at all, infra error — is about evidence a challenge cannot supply.
    def recaptcha_failed_on_score_only?
      @recaptcha_failed_on_score_only.present?
    end

    def recaptcha_assessment(site_key:)
      token = params["g-recaptcha-response"]
      if token.is_a?(String) && token.length > MAX_RECAPTCHA_TOKEN_LENGTH
        Rails.logger.error("Oversized reCAPTCHA token rejected without verification: #{token.length} characters")
        return { valid: false, score: nil, hostname: nil, infra_error: false }
      end

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
      value = $redis.get(RedisKey.recaptcha_score_threshold(surface)).presence ||
        RECAPTCHA_SCORE_THRESHOLD_DEFAULTS[surface.to_sym]
      return nil if value.nil?

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
      # Only the top level of the verification response is guaranteed to be an object, so
      # tokenProperties.hostname can arrive as any JSON scalar. A non-string is not a hostname
      # we can allow, and every comparison below would raise on it — which lands on the caller's
      # 500 rather than a clean failed verification.
      return false unless hostname.is_a?(String)
      return false if hostname.blank?

      # Google echoes the hostname as the browser sent it, so a legal absolute FQDN arrives
      # with its trailing dot and in the browser's casing. Rack does not strip either
      # (Request#host only splits the port), so a "<seller>.gumroad.com." visitor was refused
      # with a valid token and no way to fix it — the edge normalizes the Host header Rails
      # sees, which is why nothing but this path noticed.
      hostname = hostname.downcase.delete_suffix(".")

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
