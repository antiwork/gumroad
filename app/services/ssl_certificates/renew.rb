# frozen_string_literal: true

module SslCertificates
  class Renew < Base
    # Smear the fanout so the `low` queue (which the autoscaler keys on) doesn't
    # spike hourly; renewals run 15 days before expiry, so an hour's delay is
    # immaterial.
    FANOUT_WINDOW = 1.hour

    def process
      custom_domains = CustomDomain.alive.certificate_absent_or_older_than(renew_in)

      custom_domains.each do |custom_domain|
        next unless custom_domain.certificate_orderable?

        custom_domain.generate_ssl_certificate(delay: renewal_delay)
      end
    end

    private
      # The unique lock on GenerateSslCertificate dedupes per domain when two
      # hourly runs overlap.
      def renewal_delay
        2 + rand(FANOUT_WINDOW.to_i)
      end
  end
end
