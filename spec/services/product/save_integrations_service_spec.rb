# frozen_string_literal: true

require "spec_helper"

describe Product::SaveIntegrationsService do
  let(:product) { create(:product) }

  def get_integration_class(integration_name)
    case integration_name
    when "circle"
      CircleIntegration
    when "discord"
      DiscordIntegration
    when "zoom"
      ZoomIntegration
    when "google_calendar"
      GoogleCalendarIntegration
    else
      raise "Unknown integration: #{integration_name}"
    end
  end

  describe ".perform" do
    shared_examples "manages integrations" do
      it "adds a new integration" do
        expect do
          described_class.perform(product, { integration_name => new_integration_params })
        end.to change { Integration.count }.by(1)
           .and change { ProductIntegration.count }.by(1)

        product_integration = ProductIntegration.last
        integration = Integration.last

        expect(product_integration.integration).to eq(integration)
        expect(product_integration.product).to eq(product)
        expect(integration.type).to eq(Integration.type_for(integration_name))
        new_integration_params.each do |key, value|
          expect(integration.send(key)).to eq(value)
        end
      end

      it "modifies an existing integration" do
        product.active_integrations << create("#{integration_name}_integration".to_sym)

        expect do
          described_class.perform(product, { integration_name => modified_integration_params })
        end.to change { Integration.count }.by(0)
           .and change { ProductIntegration.count }.by(0)

        product_integration = ProductIntegration.last
        integration = Integration.last

        expect(product_integration.integration).to eq(integration)
        expect(product_integration.product).to eq(product)
        expect(integration.type).to eq(Integration.type_for(integration_name))
        modified_integration_params.each do |key, value|
          expect(integration.send(key)).to eq(value)
        end
      end

      it "calls disconnect if integration is removed" do
        product.active_integrations << create("#{integration_name}_integration".to_sym)

        expect_any_instance_of(get_integration_class(integration_name)).to receive(:disconnect!).and_return(true)
        expect do
          described_class.perform(product, {})
        end.to change { product.active_integrations.count }.by(-1)

        expect(product.live_product_integrations.pluck(:integration_id)).to match_array []
      end

      it "does not call disconnect if integration is removed but the same integration is present on another product by same user" do
        integration_1 = create("#{integration_name}_integration".to_sym)
        integration_2 = create("#{integration_name}_integration".to_sym)
        product.active_integrations << integration_1
        product_2 = create(:product, user: product.user, active_integrations: [integration_2])

        if integration_1.same_connection?(integration_2)
          expect_any_instance_of(get_integration_class(integration_name)).to_not receive(:disconnect!)
        end
        expect do
          described_class.perform(product, {})
        end.to change { product.active_integrations.count }.by(-1)

        expect(product.live_product_integrations.pluck(:integration_id)).to match_array []
        expect(product_2.live_product_integrations.pluck(:integration_id)).to match_array [integration_2.id]
      end
    end

    describe "circle integration" do
      let(:integration_name) { "circle" }
      let(:new_integration_params) { { "api_key" => GlobalConfig.get("CIRCLE_API_KEY"), "community_id" => "0", "space_group_id" => "0", "keep_inactive_members" => false } }
      let(:modified_integration_params) { { "api_key" => "modified_api_key", "community_id" => "1", "space_group_id" => "1", "keep_inactive_members" => true } }

      it_behaves_like "manages integrations"
    end

    describe "discord integration" do
      let(:server_id) { "0" }
      let(:integration_name) { "discord" }
      let(:new_integration_params) { { "server_id" => server_id, "server_name" => "Gaming", "username" => "gumbot", "keep_inactive_members" => false } }
      let(:modified_integration_params) { { "server_id" => "1", "server_name" => "Tech", "username" => "techuser", "keep_inactive_members" => true } }

      it_behaves_like "manages integrations"

      describe "disconnection" do
        let(:request_header) { { "Authorization" => "Bot #{DISCORD_BOT_TOKEN}" } }
        let!(:discord_integration) do
          integration = create(:discord_integration, server_id:)
          product.active_integrations << integration
          integration
        end

        it "removes bot from server if server id is valid" do
          WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}").
            with(headers: request_header).
            to_return(status: 204)

          expect do
            described_class.perform(product, {})
          end.to change { product.active_integrations.count }.by(-1)

          expect(product.live_product_integrations.pluck(:integration_id)).to match_array []
        end

        it "fails if bot is not added to server" do
          WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}").
            with(headers: request_header).
            to_return(status: 404, body: { code: Discordrb::Errors::UnknownMember.code }.to_json)

          expect do
            described_class.perform(product, {})
          end.to change { product.active_integrations.count }.by(0)
             .and raise_error(Link::LinkInvalid)

          expect(product.live_product_integrations.pluck(:integration_id)).to match_array [discord_integration].map(&:id)
        end
      end
    end

    describe "zoom integration" do
      let(:integration_name) { "zoom" }
      let(:new_integration_params) { { "user_id" => "0", "email" => "test@zoom.com", "access_token" => "test_access_token", "refresh_token" => "test_refresh_token" } }
      let(:modified_integration_params) { { "user_id" => "1", "email" => "test2@zoom.com", "access_token" => "test_access_token", "refresh_token" => "test_refresh_token" } }

      it_behaves_like "manages integrations"
    end

    describe "google calendar integration" do
      let(:integration_name) { "google_calendar" }
      let(:new_integration_params) { { "calendar_id" => "0", "calendar_summary" => "Holidays", "access_token" => "test_access_token", "refresh_token" => "test_refresh_token", "email" => "hi@gmail.com" } }
      let(:modified_integration_params) { { "calendar_id" => "1", "calendar_summary" => "Meetings", "access_token" => "test_access_token", "refresh_token" => "test_refresh_token", "email" => "hi@gmail.com" } }

      it_behaves_like "manages integrations"

      describe "disconnection" do
        let!(:google_calendar_integration) do
          integration = create(:google_calendar_integration)
          product.active_integrations << integration
          integration
        end

        it "succeeds if the gumroad app is successfully disconnected from google account" do
          WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/revoke").
            with(query: { token: google_calendar_integration.access_token }).to_return(status: 200)

          expect do
            described_class.perform(product, {})
          end.to change { product.active_integrations.count }.by(-1)

          expect(product.live_product_integrations.pluck(:integration_id)).to match_array []
        end

        it "fails if disconnecting the gumroad app from google fails" do
          WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/revoke").
            with(query: { token: google_calendar_integration.access_token }).to_return(status: 404)

          expect do
            described_class.perform(product, {})
          end.to change { product.active_integrations.count }.by(0)
             .and raise_error(Link::LinkInvalid)

          expect(product.live_product_integrations.pluck(:integration_id)).to match_array [google_calendar_integration.id]
        end
      end
    end
  end
end
