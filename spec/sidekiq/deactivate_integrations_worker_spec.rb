# frozen_string_literal: true

require "spec_helper"

describe DeactivateIntegrationsWorker do
  it "calls #deactivate for all integrations" do
    purchase = create(:free_purchase)

    [Integrations::CircleIntegrationService, Integrations::DiscordIntegrationService].each do |integration_service|
      expect_any_instance_of(integration_service).to receive(:deactivate).with(purchase)
    end

    described_class.new.perform(purchase.id)
  end

  it "errors out if purchase is not found" do
    expect { described_class.new.perform(1) }.to raise_error(ActiveRecord::RecordNotFound).with_message("Couldn't find Purchase with 'id'=1")

    [Integrations::CircleIntegrationService, Integrations::DiscordIntegrationService].each do |integration_service|
      expect_any_instance_of(integration_service).to_not receive(:deactivate)
    end
  end

  it "deactivates integrations for other purchases on the same subscription" do
    product = create(:membership_product)
    discord_integration = create(:discord_integration)
    product.product_integrations.create!(integration: discord_integration)

    purchase = create(:membership_purchase, link: product, is_gift_sender_purchase: true)
    giftee_purchase = create(:purchase,
                             link: product,
                             subscription: purchase.subscription,
                             is_original_subscription_purchase: false,
                             is_gift_receiver_purchase: true,
                             purchase_state: "gift_receiver_purchase_successful",
                             price_cents: 0)
    create(:gift, gifter_purchase: purchase, giftee_purchase:)
    PurchaseIntegration.create!(purchase: giftee_purchase,
                                integration: discord_integration,
                                discord_user_id: "disc-123")

    circle_service_instance = instance_double(Integrations::CircleIntegrationService)
    discord_service_instance = instance_double(Integrations::DiscordIntegrationService)
    allow(Integrations::CircleIntegrationService).to receive(:new).and_return(circle_service_instance)
    allow(Integrations::DiscordIntegrationService).to receive(:new).and_return(discord_service_instance)
    expect(circle_service_instance).to receive(:deactivate).with(purchase)
    expect(circle_service_instance).to receive(:deactivate).with(giftee_purchase)
    expect(discord_service_instance).to receive(:deactivate).with(purchase)
    expect(discord_service_instance).to receive(:deactivate).with(giftee_purchase)

    described_class.new.perform(purchase.id)
  end
end
