# frozen_string_literal: true

class ReissueSslCertificateForUpdatedCustomDomains
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :low

  def perform
    CustomDomain.alive.where.not(ssl_certificate_issued_at: nil).find_each do |custom_domain|
      verification_service = CustomDomainVerificationService.new(domain: custom_domain.domain)

      unless verification_service.has_valid_ssl_certificates?
        custom_domain.reset_ssl_certificate_issued_at!
        custom_domain.generate_ssl_certificate
      end
    end
  end
end
