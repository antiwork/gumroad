# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit Integrations edit - Google Calendar", type: :system, js: true) do
  include ProductTieredPricingHelpers
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller, created_at: 60.days.ago) }

  before :each do
    @product = create(:call_product, user: seller)
    @vcr_cassette_prefix = "Product Edit Integrations edit"
    Feature.activate(:google_calendar_link)
  end

  describe "google calendar integration" do
    let(:google_calendar_integration) { create(:google_calendar_integration) }
    let(:calendar_id) { google_calendar_integration.calendar_id }
    let(:calendar_summary) { google_calendar_integration.calendar_summary }
    let(:email) { google_calendar_integration.email }

    context "with proxy", billy: true do
      let(:host_with_port) { "127.0.0.1:31337" }

      before do
        login_as seller
      end

      it "adds a new integration" do
        proxy.stub("https://accounts.google.com:443/o/oauth2/auth").and_return(redirect_to: oauth_redirect_integrations_google_calendar_index_url(code: "test_code", host: host_with_port))

        WebMock.stub_request(:post, "https://oauth2.googleapis.com/token").
          to_return(status: 200,
                    body: { access_token: "test_access_token", refresh_token: "test_refresh_token" }.to_json,
                    headers: { content_type: "application/json" })

        WebMock.stub_request(:get, "https://www.googleapis.com/oauth2/v2/userinfo").
          with(query: { access_token: "test_access_token" }).
          to_return(status: 200,
                    body: { email: email }.to_json,
                    headers: { content_type: "application/json" })

        WebMock.stub_request(:get, "https://www.googleapis.com/calendar/v3/users/me/calendarList").
          with(headers: { "Authorization" => "Bearer test_access_token" }).
          to_return(status: 200,
                    body: { items: [{ id: calendar_id, summary: calendar_summary }] }.to_json,
                    headers: { content_type: "application/json" })

        expect do
          visit edit_link_url(@product, host: host_with_port)

          check "Connect with Google Calendar to sync your calls", allow_label_click: true
          expect(page).to have_button "Disconnect Google Calendar"

          save_change
        end.to change { Integration.count }.by(1)
          .and change { ProductIntegration.count }.by(1)

        product_integration = ProductIntegration.last
        integration = Integration.last

        expect(product_integration.integration).to eq(integration)
        expect(product_integration.product).to eq(@product)
        expect(integration.type).to eq(Integration.type_for(Integration::GOOGLE_CALENDAR))
        expect(integration.calendar_id).to eq(calendar_id)
        expect(integration.calendar_summary).to eq(calendar_summary)
        expect(integration.email).to eq(email)
      end

      it "shows error if oauth authorization fails" do
        proxy.stub("https://accounts.google.com:443/o/oauth2/auth").and_return(redirect_to: oauth_redirect_integrations_google_calendar_index_url(error: "error_message", host: host_with_port))

        visit edit_link_url(@product, host: host_with_port)
        check "Connect with Google Calendar to sync your calls", allow_label_click: true
        click_on "Connect to Google Calendar"

        expect_alert_message "Could not connect to your Google Calendar account, please try again."
      end
    end

    context "without proxy" do
      include_context "with switching account to user as admin for seller"

      it "shows correct details if saved integration exists" do
        @product.active_integrations << google_calendar_integration

        visit edit_link_path(@product)

        within_section "Integrations", section_element: :section do
          expect(page).to have_checked_field "Connect with Google Calendar to sync your calls"
          expect(page).to have_button "Disconnect Google Calendar"
          expect(page).to have_select "calendar-select", selected: calendar_summary
        end
      end

      it "disconnects google calendar correctly" do
        @product.active_integrations << google_calendar_integration

        expect do
          visit edit_link_path(@product)
          click_on "Disconnect Google Calendar"
          expect(page).to have_button "Connect to Google Calendar"
          save_change
        end.to change { Integration.count }.by(0)
          .and change { ProductIntegration.count }.by(0)
          .and change { @product.reload.active_integrations.count }.from(1).to(0)

        expect(ProductIntegration.first.deleted?).to eq(true)
        expect(@product.reload.live_product_integrations).to be_empty
      end

      it "does not show the checkbox when the feature flag is disabled" do
        Feature.deactivate(:google_calendar_link)

        visit edit_link_path(@product)

        within_section "Integrations", section_element: :section do
          expect(page).not_to have_field "Connect with Google Calendar to sync your calls"
          expect(page).not_to have_button "Connect to Google Calendar"
        end
      end
    end
  end
end
