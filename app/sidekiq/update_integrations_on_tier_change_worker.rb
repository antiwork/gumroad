# frozen_string_literal: true

class UpdateIntegrationsOnTierChangeWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(subscription_id)
    subscription = Subscription.find(subscription_id)

    [Integrations::CircleIntegrationService, Integrations::DiscordIntegrationService].each do |integration_service|
      integration_service.new.update_on_tier_change(subscription)
    end
  end
end
