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

  def perform(id)
    if SslCertificates::Generate.supported_environment?
      custom_domain = CustomDomain.find(id)
      return if custom_domain.deleted? # The domain was deleted after this job was enqueued

      begin
        SslCertificates::Generate.new(custom_domain).process
      rescue Acme::Client::Error::RateLimited => e
        # The Let's Encrypt account-wide order limit was hit. This says nothing
        # about this particular domain, and Sidekiq's 5 retries all happen
        # within ~10 minutes — far inside the 3-hour rate-limit window — so
        # letting the error retry normally guarantees the job exhausts its
        # retries and fires the "SSL certificate not provisioned" alert for a
        # perfectly healthy domain. Reschedule for after the limit resets
        # instead; real per-domain failures still retry and alert as before.
        self.class.perform_in(rate_limit_retry_delay(e), id)
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
