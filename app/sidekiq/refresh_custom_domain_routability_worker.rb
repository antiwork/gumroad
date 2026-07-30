# frozen_string_literal: true

class RefreshCustomDomainRoutabilityWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(custom_domain_id)
    custom_domain = CustomDomain.alive.find_by(id: custom_domain_id)
    return unless custom_domain&.active?
    return unless custom_domain.routability_refresh_due?

    CustomDomainRoutabilityService.new(custom_domain).process
  end
end
