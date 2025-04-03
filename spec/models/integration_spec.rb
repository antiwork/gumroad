# frozen_string_literal: true

require "spec_helper"

describe Integration do
  describe "#type_for" do
    it "returns the type for the given integration name" do
      { Integration::CIRCLE => CircleIntegration.name,
        Integration::DISCORD => DiscordIntegration.name,
        Integration::ZOOM => ZoomIntegration.name,
        Integration::GOOGLE_CALENDAR => GoogleCalendarIntegration.name
      }.each do |name, expected_type|
        expect(Integration.type_for(name)).to eq(expected_type)
      end
    end
  end

  describe "#class_for" do
    it "returns the class for the given integration name" do
      { Integration::CIRCLE => CircleIntegration,
        Integration::DISCORD => DiscordIntegration,
        Integration::ZOOM => ZoomIntegration,
        Integration::GOOGLE_CALENDAR => GoogleCalendarIntegration
      }.each do |name, expected_class|
        expect(Integration.class_for(name)).to eq(expected_class)
      end
    end
  end

  describe "#name" do
    it "returns the name" do
      { Integration::CIRCLE => create(:circle_integration),
        Integration::DISCORD => create(:discord_integration),
        Integration::ZOOM => create(:zoom_integration),
        Integration::GOOGLE_CALENDAR => create(:google_calendar_integration)
      }.each do |expected_name, integration|
        expect(integration.name).to eq(expected_name)
      end
    end
  end

  describe ".enabled_integrations_for" do
    it "returns the enabled integrations on a purchase" do
      product = create(:product, active_integrations: [create(:circle_integration)])
      purchase = create(:purchase, link: product)
      expect(Integration.enabled_integrations_for(purchase)).to eq({ "circle" => true, "discord" => false, "zoom" => false, "google_calendar" => false })
    end

    it "does not consider deleted integrations as enabled" do
      product = create(:product, active_integrations: [create(:circle_integration), create(:discord_integration)])
      product.product_integrations.first.mark_deleted!
      purchase = create(:purchase, link: product)
      expect(Integration.enabled_integrations_for(purchase)).to eq({ "circle" => false, "discord" => true, "zoom" => false, "google_calendar" => false })
    end
  end

  describe "scopes" do
    describe "by_name" do
      it "returns collection of integrations of the given integration type" do
        integration_1 = create(:circle_integration)
        create(:discord_integration)
        integration_3 = create(:circle_integration)

        expect(Integration.by_name(Integration::CIRCLE)).to eq([integration_1, integration_3])
      end
    end
  end

  describe "associations" do
    context "has one `product_integration`" do
      it "returns product_integration if exists" do
        integration = create(:circle_integration)
        product = create(:product, active_integrations: [integration])

        expect(integration.product_integration.product_id).to eq(product.id)
      end
    end
  end
end
