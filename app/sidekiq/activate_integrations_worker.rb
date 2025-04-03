# frozen_string_literal: true

class ActivateIntegrationsWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(purchase_id)
    purchase = Purchase.find(purchase_id)
    Integrations::CircleIntegrationService.new.activate(purchase)
  end
end
