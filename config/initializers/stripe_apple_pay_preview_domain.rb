# frozen_string_literal: true

# Preview apps must register their unique hostname with Stripe for the Apple Pay button to
# render; see StagingApplePayDomainRegistration.
#
# The registration runs in a thread rather than a Sidekiq job on purpose: preview apps run no
# Sidekiq process of their own (docker/web/server.sh starts only the Rails server) but share
# staging's Redis, so an enqueued job would be picked up by staging's main workers — which run
# main-branch code (where a branch's classes may not exist) and don't have the preview app's
# CUSTOM_DOMAIN env. Best-effort: a failure here should never take the preview app down, and
# /healthcheck/apple_pay_domain re-runs the registration on demand.
#
# The service is referenced only inside after_initialize because autoloadable constants can't be
# loaded while initializers run.
Rails.application.config.after_initialize do
  next unless StagingApplePayDomainRegistration.applicable?

  Thread.new do
    Rails.logger.info(StagingApplePayDomainRegistration.register!.message)
  rescue StandardError => e
    Rails.logger.error("Apple Pay domain registration failed: #{e.message}")
  end
end
