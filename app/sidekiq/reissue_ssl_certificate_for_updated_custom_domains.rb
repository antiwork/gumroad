# frozen_string_literal: true

class ReissueSslCertificateForUpdatedCustomDomains
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :low

  def perform
    CustomDomain.alive.where.not(ssl_certificate_issued_at: nil).find_each do |custom_domain|
      # Legacy records can carry domains that fail current validations (e.g.
      # empty labels like "example..com"). reset_ssl_certificate_issued_at!
      # runs save!, which would raise RecordInvalid for them and — with
      # retry: 0 — abort the whole sweep, leaving every domain after them
      # unrenewed. Skip them; they can't get a certificate anyway.
      next unless custom_domain.valid?

      verification_service = CustomDomainVerificationService.new(domain: custom_domain.domain)

      unless verification_service.has_valid_ssl_certificates?
        custom_domain.reset_ssl_certificate_issued_at!
        custom_domain.generate_ssl_certificate
      end
    end
  end
end
