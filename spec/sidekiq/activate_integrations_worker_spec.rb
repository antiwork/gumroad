# frozen_string_literal: true

require "spec_helper"

describe ActivateIntegrationsWorker do
  it "calls CircleIntegrationService#activate" do
    purchase = create(:purchase)

    expect_any_instance_of(Integrations::CircleIntegrationService).to receive(:activate).with(purchase)
    described_class.new.perform(purchase.id)
  end

  it "errors out if purchase is not found" do
    expect { described_class.new.perform(1) }.to raise_error(ActiveRecord::RecordNotFound).with_message("Couldn't find Purchase with 'id'=1")
    expect_any_instance_of(Integrations::CircleIntegrationService).to_not receive(:activate)
  end
end
