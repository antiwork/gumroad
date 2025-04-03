# frozen_string_literal: true

class CustomDomainVerificationWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(custom_domain_id)
    custom_domain = CustomDomain.find(custom_domain_id)

    return if custom_domain.deleted?
    return unless custom_domain.valid?

    custom_domain.verify
    custom_domain.save!
  end
end
