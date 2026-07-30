# frozen_string_literal: true

class RefreshCustomDomainRoutabilityWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(custom_domain_id)
    custom_domain = CustomDomain.alive.find_by(id: custom_domain_id)
    return unless custom_domain&.active?

    checked_domain = custom_domain.domain
    resolving_domains = CustomDomainVerificationService
      .new(domain: checked_domain)
      .domains_resolving_to_gumroad

    custom_domain.set_routability!(
      resolving_domains.include?(checked_domain),
      checked_domain:
    )
  end
end
