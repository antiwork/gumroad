# frozen_string_literal: true

require "spec_helper"

describe UpdateIntegrationsOnTierChangeWorker do
  it "calls #update_on_tier_change for all integrations" do
    purchase = create(:membership_purchase, purchase_sales_tax_info: PurchaseSalesTaxInfo.create(business_vat_id: 0))
    subscription = purchase.subscription
    new_tier = create(:variant, variant_category: purchase.link.tier_category, name: "Tier 3")
    subscription.update_current_plan!(
      new_variants: [new_tier],
      new_price: create(:price),
      perceived_price_cents: 0,
      is_applying_plan_change: true,
    )

    [Integrations::CircleIntegrationService, Integrations::DiscordIntegrationService].each do |integration_service|
      expect_any_instance_of(integration_service).to receive(:update_on_tier_change).with(subscription)
    end

    described_class.new.perform(subscription.id)
  end

  it "errors out if subscription is not found" do
    expect { described_class.new.perform(1) }.to raise_error(ActiveRecord::RecordNotFound).with_message("Couldn't find Subscription with 'id'=1")

    [Integrations::CircleIntegrationService, Integrations::DiscordIntegrationService].each do |integration_service|
      expect_any_instance_of(integration_service).to_not receive(:update_on_tier_change)
    end
  end
end
