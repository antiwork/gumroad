# frozen_string_literal: true

class CustomDomainVerificationWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(custom_domain_id)
    custom_domain = CustomDomain.find(custom_domain_id)

    return if custom_domain.deleted?
    return unless custom_domain.valid?

    observed_at = Time.current
    verification_service = CustomDomainVerificationService.new(domain: custom_domain.domain)
    custom_domain.verify(verification_service:)
    custom_domain.save!
    CustomDomainRoutabilityService.new(custom_domain, verification_service:, observed_at:).process
  end
end
