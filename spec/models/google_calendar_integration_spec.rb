# frozen_string_literal: true

require "spec_helper"

describe GoogleCalendarIntegration do
  it "creates the correct json details" do
    integration = create(:google_calendar_integration)
    GoogleCalendarIntegration::INTEGRATION_DETAILS.each do |detail|
      expect(integration.respond_to?(detail)).to eq true
    end
  end

  describe "#as_json" do
    it "returns the correct json object" do
      integration = create(:google_calendar_integration)
      expect(integration.as_json).to eq({ keep_inactive_members: false,
                                          name: "google_calendar", integration_details: {
                                            "calendar_id" => "0",
                                            "calendar_summary" => "Holidays",
                                            "email" => "hi@gmail.com",
                                            "access_token" => "test_access_token",
                                            "refresh_token" => "test_refresh_token",
                                          } })
    end
  end

  describe ".is_enabled_for" do
    it "returns true if a google calendar integration is enabled on the product" do
      product = create(:product, active_integrations: [create(:google_calendar_integration)])
      purchase = create(:purchase, link: product)
      expect(GoogleCalendarIntegration.is_enabled_for(purchase)).to eq(true)
    end

    it "returns false if a google calendar integration is not enabled on the product" do
      product = create(:product, active_integrations: [create(:circle_integration)])
      purchase = create(:purchase, link: product)
      expect(GoogleCalendarIntegration.is_enabled_for(purchase)).to eq(false)
    end

    it "returns false if a deleted google calendar integration exists on the product" do
      product = create(:product, active_integrations: [create(:google_calendar_integration)])
      purchase = create(:purchase, link: product)
      product.product_integrations.first.mark_deleted!
      expect(GoogleCalendarIntegration.is_enabled_for(purchase)).to eq(false)
    end
  end

  describe "#disconnect!" do
    let(:google_calendar_integration) { create(:google_calendar_integration) }

    it "disconnects gumroad app from google account" do
      WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/revoke").
        with(query: { token: google_calendar_integration.access_token }).to_return(status: 200)

      expect(google_calendar_integration.disconnect!).to eq(true)
    end

    it "fails if disconnect request fails" do
      WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/revoke").
        with(query: { token: google_calendar_integration.access_token }).to_return(status: 400)

      expect(google_calendar_integration.disconnect!).to eq(false)
    end
  end

  describe "#same_connection?" do
    let(:google_calendar_integration) { create(:google_calendar_integration) }
    let(:same_connection_google_calendar_integration) { create(:google_calendar_integration) }
    let(:other_google_calendar_integration) { create(:google_calendar_integration, email: "other@gmail.com") }

    it "returns true if the integrations have the same email" do
      expect(google_calendar_integration.same_connection?(same_connection_google_calendar_integration)).to eq(true)
    end

    it "returns false if the integrations have different emails" do
      expect(google_calendar_integration.same_connection?(other_google_calendar_integration)).to eq(false)
    end

    it "returns false if the integrations have different types" do
      same_connection_google_calendar_integration.update(type: "NotGoogleCalendarIntegration")
      expect(google_calendar_integration.same_connection?(same_connection_google_calendar_integration)).to eq(false)
    end
  end
end
