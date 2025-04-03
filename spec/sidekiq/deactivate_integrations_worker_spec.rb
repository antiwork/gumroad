# frozen_string_literal: true

require "spec_helper"

describe DeactivateIntegrationsWorker do
  it "calls #deactivate for all integrations" do
    purchase = create(:purchase)

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
end
