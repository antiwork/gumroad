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

    describe "save contract (Product::SaveContract)" do
      let(:seller) { product.user }
      let!(:discord_integration) do
        integration = create(:discord_integration)
        product.active_integrations << integration
        integration
      end

      def contract_for(contract_params)
        # Mirrors the controller wiring (LinksController#product_save_contract):
        # the contract is handed plain, deeply-symbolized hashes.
        Product::SaveContract.new(params: contract_params.deep_symbolize_keys, product:)
      end

      context "when the :product_editor_save_contract flag is off" do
        it "preserves today's behaviour: absent integrations still disconnects everything" do
          contract = contract_for({ editor_revision: "rev-1" })
          expect(contract.enforced?).to eq(false)

          expect_any_instance_of(DiscordIntegration).to receive(:disconnect!).and_return(true)
          expect do
            described_class.perform(product, nil, contract:)
          end.to change { product.active_integrations.count }.by(-1)
        end
      end

      context "when the :product_editor_save_contract flag is on" do
        # Scoped deactivation, NOT `Feature.deactivate(...)`. Flipper is backed by
        # Redis with no per-worker namespace (config/initializers/feature_toggle.rb),
        # so a global deactivate in an after-hook clears the flag for every other
        # spec process sharing that Redis — which made a sibling run fail with
        # unrelated errors while this suite was green in isolation.
        before { Feature.activate_user(:product_editor_save_contract, seller) }
        after { Feature.deactivate_user(:product_editor_save_contract, seller) }

        it "does not disconnect anything when integrations is absent" do
          contract = contract_for({ editor_revision: "rev-1" })

          expect_any_instance_of(DiscordIntegration).not_to receive(:disconnect!)
          expect do
            described_class.perform(product, nil, contract:)
          end.to not_change { product.active_integrations.count }
             .and not_change { ProductIntegration.alive.count }
        end

        it "does not disconnect anything when integrations is an empty hash" do
          contract = contract_for({ integrations: {}, editor_revision: "rev-1" })

          expect_any_instance_of(DiscordIntegration).not_to receive(:disconnect!)
          expect do
            described_class.perform(product, {}, contract:)
          end.to not_change { product.active_integrations.count }
             .and not_change { ProductIntegration.alive.count }
        end

        it "does not disconnect an active integration merely omitted from a submitted payload" do
          # circle is submitted, discord is omitted — under the contract that
          # omission is not a deletion.
          circle_params = { "circle" => { "api_key" => "key", "community_id" => "0", "space_group_id" => "0" } }
          contract = contract_for({ integrations: circle_params, editor_revision: "rev-1" })

          expect_any_instance_of(DiscordIntegration).not_to receive(:disconnect!)
          expect do
            described_class.perform(product, circle_params.deep_dup, contract:)
          end.to change { product.active_integrations.count }.by(1) # circle added

          expect(product.active_integrations.map(&:name)).to match_array ["circle", "discord"]
        end

        it "disconnects exactly the explicitly deleted integrations" do
          circle_integration = create(:circle_integration)
          product.active_integrations << circle_integration

          contract = contract_for(
            {
              editor_revision: "rev-1",
              deletion_operations: { deleted_ids: { integrations: ["discord"] } },
            }
          )

          expect_any_instance_of(DiscordIntegration).to receive(:disconnect!).and_return(true)
          expect_any_instance_of(CircleIntegration).not_to receive(:disconnect!)
          expect do
            described_class.perform(product, nil, contract:)
          end.to change { product.active_integrations.count }.by(-1)

          expect(product.reload.active_integrations.map(&:name)).to match_array ["circle"]
        end

        it "ignores deleted_ids when the save carries no editor_revision (write-only save)" do
          contract = contract_for(
            { deletion_operations: { deleted_ids: { integrations: ["discord"] } } }
          )

          expect_any_instance_of(DiscordIntegration).not_to receive(:disconnect!)
          expect do
            described_class.perform(product, nil, contract:)
          end.to not_change { product.active_integrations.count }
        end

        it "disconnects everything on an explicit clear-all" do
          circle_integration = create(:circle_integration)
          product.active_integrations << circle_integration

          contract = contract_for(
            {
              editor_revision: "rev-1",
              deletion_operations: { cleared_collections: ["integrations"] },
            }
          )

          expect_any_instance_of(DiscordIntegration).to receive(:disconnect!).and_return(true)
          expect_any_instance_of(CircleIntegration).to receive(:disconnect!).and_return(true)
          expect do
            described_class.perform(product, nil, contract:)
          end.to change { product.active_integrations.count }.by(-2)
        end
      end
    end
  end
end
