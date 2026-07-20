# frozen_string_literal: true

class GenerateSslCertificate
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  # Fallback delay when the rate-limit error doesn't tell us when to retry.
  RATE_LIMIT_FALLBACK_DELAY = 1.hour
  # Random extra delay added to every rate-limited reschedule. Let's Encrypt
  # limits new certificate orders per account (300 per 3 hours), so when the
  # limit trips there is usually a backlog of queued jobs. Spreading the
  # rescheduled jobs across the next window keeps them from all firing at the
  # same instant and immediately tripping the limit again.
  RATE_LIMIT_MAX_JITTER = 3.hours
  # How many times a job may reschedule itself for rate limits before giving
  # up and letting the error propagate (so Sidekiq's retries run out and the
  # exhausted-retries alert below fires). Let's Encrypt raises RateLimited for
  # per-domain limits too (e.g. 5 certificates per exact set of hostnames per
  # week), and a domain stuck on one of those would otherwise reschedule
  # forever without ever alerting — the exact silent-outage class #488 exists
  # to catch. Ten reschedules comfortably outlasts any account-wide backlog
  # (3-hour windows) while capping a stuck domain at roughly a week of
  # rescheduling before it alerts.
  RATE_LIMIT_MAX_RESCHEDULES = 10

  # #488: surface silently-stuck SSL renewals. Once retries are exhausted the
  # ACME order has failed and `ssl_certificate_issued_at` stays NULL with no
  # other signal — report it so a stuck domain is caught without a support
  # ticket (one such domain was down over HTTPS for ~4 months unnoticed).
  sidekiq_retries_exhausted do |msg, exception|
    custom_domain_id = msg["args"].first
    domain = CustomDomain.find_by(id: custom_domain_id)&.domain
    ErrorNotifier.notify(
      "GenerateSslCertificate exhausted retries — SSL certificate not provisioned (ssl_certificate_issued_at remains unset)",
      custom_domain_id:,
      domain:,
      exception_class: exception&.class&.name,
      exception_message: exception&.message
    )
  end

  def perform(id, rate_limit_reschedules = 0)
    if SslCertificates::Generate.supported_environment?
      custom_domain = CustomDomain.find(id)
      return if custom_domain.deleted? # The domain was deleted after this job was enqueued

      begin
        SslCertificates::Generate.new(custom_domain).process
      rescue Acme::Client::Error::RateLimited => e
        # A Let's Encrypt rate limit was hit — usually the account-wide order
        # limit (which says nothing about this particular domain). Sidekiq's
        # 5 retries all happen within ~10 minutes — far inside the 3-hour
        # rate-limit window — so letting the error retry normally guarantees
        # the job exhausts its retries and fires the "SSL certificate not
        # provisioned" alert for a perfectly healthy domain. Reschedule for
        # after the limit resets instead. Because RateLimited also covers
        # per-domain limits (which can persist for a week), the reschedules
        # are capped: once the cap is hit the error propagates so the normal
        # retry/alert path takes over. Other failures retry and alert as
        # before.
        raise if rate_limit_reschedules >= RATE_LIMIT_MAX_RESCHEDULES

        delay = rate_limit_retry_delay(e)
        Rails.logger.info(
          "GenerateSslCertificate rate-limited for #{custom_domain.domain} (custom_domain_id=#{id}): " \
          "rescheduling in #{delay}s (reschedule #{rate_limit_reschedules + 1}/#{RATE_LIMIT_MAX_RESCHEDULES}) — #{e.message}"
        )
        self.class.perform_in(delay, id, rate_limit_reschedules + 1)
      end
    end
  end

  private
    def rate_limit_retry_delay(exception)
      base_delay = seconds_until_rate_limit_resets(exception) || RATE_LIMIT_FALLBACK_DELAY.to_i
      base_delay + rand(RATE_LIMIT_MAX_JITTER.to_i)
    end

    # Let's Encrypt includes the reset time in the error message, e.g.
    # "too many new orders (300) from this account in the last 3h0m0s,
    #  retry after 2026-07-20 05:14:17 UTC: see https://letsencrypt.org/..."
    # Parse it defensively — if the message format ever changes we fall back
    # to a fixed delay rather than raising.
    def seconds_until_rate_limit_resets(exception)
      match = exception.message.to_s.match(/retry after (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC)/)
      return nil unless match

      retry_at = Time.zone.parse(match[1])
      return nil if retry_at.nil?

      [(retry_at - Time.current).to_i, 0].max
    rescue ArgumentError
      nil
    end
end
