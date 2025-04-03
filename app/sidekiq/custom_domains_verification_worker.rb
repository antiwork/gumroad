# frozen_string_literal: true

class CustomDomainsVerificationWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  MAX_DURATION_TO_VERIFY_ALL_DOMAINS = 1.hour

  def perform
    CustomDomain.alive.find_each.with_index do |custom_domain, index|
      next if custom_domain.exceeding_max_failed_verification_attempts?

      CustomDomainVerificationWorker.perform_in((index % MAX_DURATION_TO_VERIFY_ALL_DOMAINS).seconds, custom_domain.id)
    end
  end
end
