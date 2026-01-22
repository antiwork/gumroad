# frozen_string_literal: true

class DeactivateIntegrationsWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(purchase_id)
    purchase = Purchase.find(purchase_id)

    purchases_to_process(purchase).each { deactivate_integrations(_1) }
  end

  private
    def purchases_to_process(purchase)
      purchases = [purchase]

      if purchase.subscription.present?
        subscription_purchases =
          purchase.subscription.purchases
                  .joins(:live_purchase_integrations)
                  .distinct
        purchases.concat(subscription_purchases)
      end

      purchases.uniq(&:id)
    end

    def deactivate_integrations(purchase)
      [Integrations::CircleIntegrationService, Integrations::DiscordIntegrationService].each do |integration_service|
        integration_service.new.deactivate(purchase)
      rescue Discordrb::Errors::NoPermission => e
        Rails.logger.warn("DeactivateIntegrationsWorker: Permissions error for #{purchase.id} - #{e.class} => #{e.message}")
        next
      end
    end
end
