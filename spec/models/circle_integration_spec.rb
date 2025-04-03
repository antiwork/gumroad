# frozen_string_literal: true

require "spec_helper"

describe CircleIntegration do
  it "creates the correct json details" do
    integration = create(:circle_integration)
    CircleIntegration::INTEGRATION_DETAILS.each do |detail|
      expect(integration.respond_to?(detail)).to eq true
    end
  end

  it "saves details correctly" do
    integration = create(:circle_integration, community_id: "0", space_group_id: "0", keep_inactive_members: true)
    expect(integration.type).to eq(Integration.type_for(Integration::CIRCLE))
    expect(integration.community_id).to eq("0")
    expect(integration.space_group_id).to eq("0")
    expect(integration.keep_inactive_members).to eq(true)
  end

  describe "#as_json" do
    it "returns the correct json object" do
      integration = create(:circle_integration)
      expect(integration.as_json).to eq({ api_key: GlobalConfig.get("CIRCLE_API_KEY"), keep_inactive_members: false,
                                          name: "circle", integration_details: {
                                            "community_id" => "3512",
                                            "space_group_id" => "43576",
                                          } })
    end
  end

  describe ".is_enabled_for" do
    it "returns true if a circle integration is enabled on the product" do
      product = create(:product, active_integrations: [create(:circle_integration)])
      purchase = create(:purchase, link: product)
      expect(CircleIntegration.is_enabled_for(purchase)).to eq(true)
    end

    it "returns false if a circle integration is not enabled on the product" do
      product = create(:product, active_integrations: [create(:discord_integration)])
      purchase = create(:purchase, link: product)
      expect(CircleIntegration.is_enabled_for(purchase)).to eq(false)
    end

    it "returns false if a deleted circle integration exists on the product" do
      product = create(:product, active_integrations: [create(:circle_integration)])
      purchase = create(:purchase, link: product)
      product.product_integrations.first.mark_deleted!
      expect(CircleIntegration.is_enabled_for(purchase)).to eq(false)
    end
  end
end
