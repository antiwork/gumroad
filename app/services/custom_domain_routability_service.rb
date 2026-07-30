# frozen_string_literal: true

class CustomDomainRoutabilityService
  def initialize(custom_domain, verification_service: CustomDomainVerificationService.new(domain: custom_domain.domain), observed_at: Time.current)
    @custom_domain = custom_domain
    @verification_service = verification_service
    @checked_domain = custom_domain.domain
    @observed_at = observed_at
  end

  def process
    unless verification_service.domains_resolving_to_gumroad.include?(checked_domain)
      return custom_domain.set_routability!(false, checked_domain:, observed_at:)
    end

    if verification_service.has_valid_ssl_certificate_for?(checked_domain)
      custom_domain.set_routability!(true, checked_domain:, observed_at:)
    elsif custom_domain.require_certificate_for_routability!(checked_domain:, observed_at:)
      GenerateSslCertificate.perform_async(custom_domain.id)
    end
  end

  private
    attr_reader :custom_domain, :verification_service, :checked_domain, :observed_at
end
