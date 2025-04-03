# frozen_string_literal: true

module SslCertificates
  class Renew < Base
    def process
      custom_domains = CustomDomain.alive.certificate_absent_or_older_than(renew_in)

      custom_domains.each do |custom_domain|
        custom_domain.generate_ssl_certificate
      end
    end
  end
end
