# frozen_string_literal: true

require "spec_helper"

describe ZoomIntegration do
  it "creates the correct json details" do
    integration = create(:zoom_integration)
    ZoomIntegration::INTEGRATION_DETAILS.each do |detail|
      expect(integration.respond_to?(detail)).to eq true
    end
  end

  it "saves details correctly" do
    integration = create(:zoom_integration)
    expect(integration.type).to eq(Integration.type_for(Integration::ZOOM))
    expect(integration.user_id).to eq("0")
    expect(integration.email).to eq("test@zoom.com")
    expect(integration.access_token).to eq("test_access_token")
    expect(integration.refresh_token).to eq("test_refresh_token")
  end

  describe "#as_json" do
    it "returns the correct json object" do
      integration = create(:zoom_integration)
      expect(integration.as_json).to eq({ keep_inactive_members: false,
                                          name: "zoom", integration_details: {
                                            "user_id" => "0",
                                            "email" => "test@zoom.com",
                                            "access_token" => "test_access_token",
                                            "refresh_token" => "test_refresh_token",
                                          } })
    end
  end

  describe ".is_enabled_for" do
    it "returns true if a zoom integration is enabled on the product" do
      product = create(:product, active_integrations: [create(:zoom_integration)])
      purchase = create(:purchase, link: product)
      expect(ZoomIntegration.is_enabled_for(purchase)).to eq(true)
    end

    it "returns false if a zoom integration is not enabled on the product" do
      product = create(:product, active_integrations: [create(:discord_integration)])
      purchase = create(:purchase, link: product)
      expect(ZoomIntegration.is_enabled_for(purchase)).to eq(false)
    end

    it "returns false if a deleted zoom integration exists on the product" do
      product = create(:product, active_integrations: [create(:zoom_integration)])
      purchase = create(:purchase, link: product)
      product.product_integrations.first.mark_deleted!
      expect(ZoomIntegration.is_enabled_for(purchase)).to eq(false)
    end
  end

  describe "#same_connection?" do
    let(:zoom_integration) { create(:zoom_integration) }
    let(:same_connection_zoom_integration) { create(:zoom_integration) }
    let(:other_zoom_integration) { create(:zoom_integration, user_id: "1") }

    it "returns true if both integrations have the same user id" do
      expect(zoom_integration.same_connection?(same_connection_zoom_integration)).to eq(true)
    end

    it "returns false if both integrations have different user ids" do
      expect(zoom_integration.same_connection?(other_zoom_integration)).to eq(false)
    end

    it "returns false if both integrations have different types" do
      same_connection_zoom_integration.update(type: "NotZoomIntegration")
      expect(zoom_integration.same_connection?(same_connection_zoom_integration)).to eq(false)
    end
  end
end
