# frozen_string_literal: true

class CustomDomainVerificationWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(custom_domain_id)
    custom_domain = CustomDomain.find(custom_domain_id)

    return if custom_domain.deleted?
    return unless custom_domain.valid?

    verification_service = CustomDomainVerificationService.new(domain: custom_domain.domain)
    custom_domain.verify(verification_service:)
    custom_domain.save!
    custom_domain.set_routability!(
      verification_service.domains_resolving_to_gumroad.include?(custom_domain.domain),
      checked_domain: custom_domain.domain
    )
  end
end
