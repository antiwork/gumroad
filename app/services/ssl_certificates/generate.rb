# frozen_string_literal: true

module SslCertificates
  class Generate < Base
    attr_reader :custom_domain

    include ActionView::Helpers::DateHelper

    def initialize(custom_domain)
      super()

      @custom_domain = custom_domain
      @domain_verification_service = CustomDomainVerificationService.new(domain: custom_domain.domain)
    end

    def process
      can_order_certificates, error_message = can_order_certificates?

      if can_order_certificates
        order_certificates
      else
        log_message(custom_domain.domain, error_message)
      end
    end

    private
      attr_reader :domain_verification_service

      def order_certificates
        domains_pointed_to_gumroad = domain_verification_service.domains_pointed_to_gumroad

        all_certificates_generated = true
        domains_pointed_to_gumroad.each do |domain|
          # `&=` will set all_certificates_generated to false if generate_certificate()
          # returns false for any of the domains.
          all_certificates_generated &= generate_certificate(domain)
        end

        if all_certificates_generated
          custom_domain.set_ssl_certificate_issued_at!
          domains_pointed_to_gumroad.each { |domain| log_message(domain, "Issued SSL certificate.") }
        else
          # Reset ssl_certificate_issued_at
          custom_domain.reset_ssl_certificate_issued_at!

          # SSL certificate generation failed. Skip retrying for 1 day.
          Rails.cache.write(domain_check_cache_key, false, expires_in: invalid_domain_cache_expires_in)
          log_message(custom_domain.domain, "LetsEncrypt order failed. Next retry in #{time_ago_in_words(invalid_domain_cache_expires_in.from_now)}.")
        end
      end

      def domain_check_cache_key
        "domain_check_#{custom_domain.domain}"
      end

      def generate_certificate(domain)
        certificate_authority.new(domain).process
      end

      def hourly_rate_limit_reached?
        # Check if we have hit the rate limit.
        # We don't have to add `.alive` scope here because we should count the deleted domain
        # if a certificate was issued for it.
        CustomDomain.certificates_younger_than(rate_limit_hours).count > rate_limit
      end

      def can_order_certificates?
        return false, "Has valid certificate" if custom_domain.has_valid_certificate?(renew_in)
        return false, "Hourly limit reached" if hourly_rate_limit_reached?
        return false, "Invalid domain" unless custom_domain.valid?

        Rails.cache.fetch(domain_check_cache_key, expires_in: invalid_domain_cache_expires_in) do
          if domain_verification_service.points_to_gumroad?
            return true
          else
            return false, "No domains pointed to Gumroad"
          end
        end
      end
  end
end
