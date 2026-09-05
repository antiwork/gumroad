# frozen_string_literal: true

module SslCertificates
  class Renew < Base
    # Spread the hourly renewal fanout across the whole hour so the `low`
    # queue — and the Sidekiq fleet the autoscaler keys on it — don't spike at
    # the top of every hour. Jobs land in the scheduled set and drain
    # gradually; certificates are renewed at 75 days against a 90-day lifetime,
    # so up to an hour's extra delay is immaterial.
    FANOUT_WINDOW = 1.hour

    def process
      custom_domains = CustomDomain.alive.certificate_absent_or_older_than(renew_in)

      custom_domains.each do |custom_domain|
        next unless custom_domain.certificate_orderable?

        custom_domain.generate_ssl_certificate(delay: renewal_delay)
      end
    end

    private
      # Uniform random offset within the fanout window, on top of the 2s base
      # delay. The unique lock on GenerateSslCertificate (keyed on the domain
      # id) means only one pending renewal exists per domain even if two hourly
      # runs overlap, and it replaces the stale pending job with the newest.
      def renewal_delay
        2 + rand(FANOUT_WINDOW.to_i)
      end
  end
end
