# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit Integrations edit - Discord", type: :system, js: true) do
  include ProductTieredPricingHelpers
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }

  before :each do
    @product = create(:product_with_pdf_file, user: seller, size: 1024)
    @vcr_cassette_prefix = "Product Edit Integrations edit"
  end

  describe "discord integration" do
    let(:discord_integration) { create(:discord_integration) }
    let(:server_id) { discord_integration.server_id }
    let(:server_name) { discord_integration.server_name }
    let(:username) { discord_integration.username }

    context "with proxy", billy: true do
      let(:host_with_port) { "127.0.0.1:31337" }

      # Specs are failing on Buildkite when the shared context below replaces the seller login; they pass on local
      # The issue is related to using Puffing Billy as the specs within `without proxy` work with the shared context
      # TODO: enable shared context (and remove before block), and investigate failure of specs on Buildkite
      before do
        login_as seller
      end
      # include_context "with switching account to user as admin for seller", host: "127.0.0.1:31337"

      it "adds a new integration" do
        proxy.stub("https://www.discord.com:443/api/oauth2/authorize").and_return(redirect_to: oauth_redirect_integrations_discord_index_url(code: "test_code", host: host_with_port))

        WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
          to_return(status: 200,
                    body: { access_token: "test_access_token", guild: { id: server_id, name: server_name } }.to_json,
                    headers: { content_type: "application/json" })

        WebMock.stub_request(:get, "#{Discordrb::API.api_base}/users/@me").
          with(headers: { "Authorization" => "Bearer test_access_token" }).
          to_return(status: 200,
                    body: { username: }.to_json,
                    headers: { content_type: "application/json" })

        expect do
          visit edit_link_url(@product, host: host_with_port)

          check "Invite your customers to a Discord server", allow_label_click: true
          click_on "Connect to Discord"
          expect(page).to have_button "Disconnect Discord"
          expect(page).to_not have_status(text: "Your integration is not assigned to any version. Check your versions' settings.")
          save_change
        end.to change { Integration.count }.by(1)
          .and change { ProductIntegration.count }.by(1)

        product_integration = ProductIntegration.last
        integration = Integration.last

        expect(product_integration.integration).to eq(integration)
        expect(product_integration.product).to eq(@product)
        expect(integration.type).to eq(Integration.type_for(Integration::DISCORD))
        expect(integration.server_id).to eq(server_id)
        expect(integration.server_name).to eq(server_name)
        expect(integration.username).to eq(username)
        expect(integration.keep_inactive_members).to eq(false)
      end

      it "shows error if oauth authorization fails" do
        proxy.stub("https://www.discord.com:443/api/oauth2/authorize").and_return(redirect_to: oauth_redirect_integrations_discord_index_url(error: "error_message", host: host_with_port))

        visit edit_link_url(@product, host: host_with_port)
        check "Invite your customers to a Discord server", allow_label_click: true
        click_on "Connect to Discord"

        expect_alert_message "Could not connect to your Discord account, please try again."
      end

      it "shows error if getting server info fails" do
        proxy.stub("https://www.discord.com:443/api/oauth2/authorize").and_return(redirect_to: oauth_redirect_integrations_discord_index_url(code: "test_code", host: host_with_port))

        visit edit_link_url(@product, host: host_with_port)
        check "Invite your customers to a Discord server", allow_label_click: true
        click_on "Connect to Discord"

        expect_alert_message "Could not connect to your Discord account, please try again."
      end

      it "creates an integration for the product and enables integration for a newly created tier" do
        proxy.stub("https://www.discord.com:443/api/oauth2/authorize").and_return(redirect_to: oauth_redirect_integrations_discord_index_url(code: "test_code", host: host_with_port))

        WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
          to_return(status: 200,
                    body: { access_token: "test_access_token", guild: { id: server_id, name: server_name } }.to_json,
                    headers: { content_type: "application/json" })

        WebMock.stub_request(:get, "#{Discordrb::API.api_base}/users/@me").
          with(headers: { "Authorization" => "Bearer test_access_token" }).
          to_return(status: 200,
                    body: { username: }.to_json,
                    headers: { content_type: "application/json" })

        product = create(:membership_product, user: seller)

        expect do
          visit edit_link_url(product, host: host_with_port)

          check "Invite your customers to a Discord server", allow_label_click: true
          click_on "Connect to Discord"
          expect(page).to have_button "Disconnect Discord"

          check "Do not remove Discord access when membership ends", allow_label_click: true

          click_on "Add tier"
          within tier_rows[0] do
            fill_in "Name", with: "New Tier"
            fill_in "Amount monthly", with: 3
            check "Enable access to Discord server", allow_label_click: true
          end

          within tier_rows[1] do
            check "Toggle recurrence option: Monthly"
            fill_in "Amount monthly", with: 3
          end

          save_change
        end.to change { Integration.count }.by(1)
           .and change { ProductIntegration.count }.by(1)
           .and change { BaseVariantIntegration.count }.by(1)

        product_integration = ProductIntegration.last
        base_variant_integration = BaseVariantIntegration.last
        integration = Integration.last

        expect(product_integration.integration).to eq(integration)
        expect(base_variant_integration.integration).to eq(integration)
        expect(base_variant_integration.base_variant.name).to eq("New Tier")
        expect(product_integration.product).to eq(product)
        expect(integration.type).to eq(Integration.type_for(Integration::DISCORD))
        expect(integration.server_id).to eq(server_id)
        expect(integration.server_name).to eq(server_name)
        expect(integration.username).to eq(username)
        expect(integration.keep_inactive_members).to eq(true)
      end

      it "creates an integration for the product and enables integration for a newly created version" do
        proxy.stub("https://www.discord.com:443/api/oauth2/authorize").and_return(redirect_to: oauth_redirect_integrations_discord_index_url(code: "test_code", host: host_with_port))

        WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
          to_return(status: 200,
                    body: { access_token: "test_access_token", guild: { id: server_id, name: server_name } }.to_json,
                    headers: { content_type: "application/json" })

        WebMock.stub_request(:get, "#{Discordrb::API.api_base}/users/@me").
          with(headers: { "Authorization" => "Bearer test_access_token" }).
          to_return(status: 200,
                    body: { username: }.to_json,
                    headers: { content_type: "application/json" })

        product = create(:product_with_pdf_file, user: seller)

        expect do
          visit edit_link_url(product, host: host_with_port)

          check "Invite your customers to a Discord server", allow_label_click: true
          click_on "Connect to Discord"
          expect(page).to have_button "Disconnect Discord"

          click_on "Add version"
          fill_in "Version name", with: "Files"

          click_on "Add version"
          within version_rows[0] do
            within version_option_rows[0] do
              fill_in "Version name", with: "New Version"
              check "Enable access to Discord server", allow_label_click: true
            end
          end
          save_change
        end.to change { Integration.count }.by(1)
          .and change { ProductIntegration.count }.by(1)
          .and change { BaseVariantIntegration.count }.by(1)

        product_integration = ProductIntegration.last
        base_variant_integration = BaseVariantIntegration.last
        integration = Integration.last

        expect(product_integration.integration).to eq(integration)
        expect(base_variant_integration.integration).to eq(integration)
        expect(base_variant_integration.base_variant.name).to eq("New Version")
        expect(product_integration.product).to eq(product)
        expect(integration.type).to eq(Integration.type_for(Integration::DISCORD))
        expect(integration.server_id).to eq(server_id)
        expect(integration.server_name).to eq(server_name)
        expect(integration.username).to eq(username)
        expect(integration.keep_inactive_members).to eq(false)
      end
    end

    context "without proxy" do
      include_context "with switching account to user as admin for seller"

      it "shows correct details if saved integration exists" do
        @product.active_integrations << discord_integration

        visit edit_link_path(@product)

        within_section "Integrations", section_element: :section do
          expect(page).to have_checked_field "Invite your customers to a Discord server"
          expect(page).to have_button "Disconnect Discord"
          expect(page).to have_text "Discord account #gumbot connected"
          expect(page).to have_text "Server name: Gaming"
        end
      end

      it "disconnects discord server correctly" do
        @product.active_integrations << discord_integration

        WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}").
          with(headers: { "Authorization" => "Bot #{DISCORD_BOT_TOKEN}" }).
          to_return(status: 204)

        expect do
          visit edit_link_path(@product)
          click_on "Disconnect Discord"
          expect(page).to have_button "Connect to Discord"
          save_change
        end.to change { Integration.count }.by(0)
          .and change { ProductIntegration.count }.by(0)
          .and change { @product.reload.active_integrations.count }.from(1).to(0)

        expect(ProductIntegration.first.deleted?).to eq(true)
        expect(@product.reload.live_product_integrations).to be_empty
      end

      it "shows error message if disconnection fails" do
        @product.active_integrations << discord_integration

        WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}").
          with(headers: { "Authorization" => "Bot #{DISCORD_BOT_TOKEN}" }).
          to_return(status: 404, body: { code: Discordrb::Errors::UnknownMember.code }.to_json)

        expect do
          visit edit_link_path(@product)
          click_on "Disconnect Discord"
          save_change(expect_message: "Could not disconnect the discord integration, please try again.")
        end.to change { Integration.count }.by(0)
          .and change { ProductIntegration.count }.by(0)
          .and change { @product.reload.active_integrations.count }.by(0)
      end

      it "does not disconnect integration if product is not saved after disconnecting" do
        @product.active_integrations << discord_integration

        WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/0").
          with(headers: { "Authorization" => "Bot #{DISCORD_BOT_TOKEN}" }).
          to_return(status: 404)

        expect do
          visit edit_link_path(@product)
          click_on "Disconnect Discord"
          expect(page).to have_button "Connect to Discord"
          expect(page).to_not have_button "Disconnect Discord"
          visit edit_link_path(@product)
          expect(page).to have_button "Disconnect Discord"
        end.to change { @product.reload.active_integrations.count }.by(0)
      end

      it "disables integration correctly" do
        @product.active_integrations << discord_integration

        WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}").
          with(headers: { "Authorization" => "Bot #{DISCORD_BOT_TOKEN}" }).
          to_return(status: 204)

        expect do
          visit edit_link_path(@product)
          expect(page).to have_button "Disconnect Discord"
          uncheck "Invite your customers to a Discord server", allow_label_click: true
          expect(page).to have_unchecked_field "Invite your customers to a Discord server"
          save_change
        end.to change { Integration.count }.by(0)
          .and change { ProductIntegration.count }.by(0)
          .and change { @product.reload.active_integrations.count }.from(1).to(0)

        expect(ProductIntegration.first.deleted?).to eq(true)
        expect(@product.reload.live_product_integrations).to be_empty

        visit edit_link_path(@product)
        expect(page).to_not have_button "Disconnect Discord"
      end


      context "integration for product with multiple versions" do
        before do
          @version_category = create(:variant_category, link: @product)
          @version_1 = create(:variant, variant_category: @version_category)
          @version_2 = create(:variant, variant_category: @version_category)
        end

        it "shows the integration toggle if product has an integration" do
          @product.active_integrations << discord_integration
          visit edit_link_path(@product)

          expect(page).to have_text "Enable access to Discord server", count: 2
        end

        it "hides the integration toggle if product does not have an integration" do
          visit edit_link_path(@product)

          expect(page).to_not have_text "Enable access to Discord server"
        end

        it "enables integration for versions" do
          @product.active_integrations << discord_integration
          visit edit_link_path(@product)
          within_section "Integrations", section_element: :section do
            expect(page).to have_unchecked_field("Enable for all versions")
            expect(page).to have_status(text: "Your integration is not assigned to any version. Check your versions' settings.")
            check "Enable for all versions", allow_label_click: true
          end
          within version_rows[0] do
            within version_option_rows[0] do
              expect(page).to have_checked_field("Enable access to Discord server")
              uncheck "Enable access to Discord server", allow_label_click: true
            end
            within version_option_rows[1] do
              expect(page).to have_checked_field("Enable access to Discord server")
            end
          end
          within_section "Integrations", section_element: :section do
            expect(page).to have_unchecked_field("Enable for all versions")
            expect(page).to_not have_status(text: "Your integration is not assigned to any version. Check your versions' settings.")
          end

          expect do
            save_change
          end.to change { Integration.count }.by(0)
            .and change { ProductIntegration.count }.by(0)
            .and change { BaseVariantIntegration.count }.by(1)

          integration = @product.active_integrations.first
          base_variant_integration = BaseVariantIntegration.first
          expect(base_variant_integration.integration).to eq(integration)
          expect(base_variant_integration.base_variant).to eq(@version_2)
        end

        it "disables integration for a version" do
          @product.active_integrations << discord_integration
          @version_1.active_integrations << discord_integration

          version_integration = @version_1.base_variant_integrations.first

          expect do
            visit edit_link_path(@product)
            within version_rows[0] do
              within version_option_rows[0] do
                uncheck "Enable access to Discord server", allow_label_click: true
              end
            end
            save_change
          end.to change { Integration.count }.by(0)
            .and change { ProductIntegration.count }.by(0)
            .and change { BaseVariantIntegration.count }.by(0)
            .and change { @version_1.active_integrations.count }.from(1).to(0)

          expect(version_integration.reload.deleted?).to eq(true)
          expect(@version_1.reload.live_base_variant_integrations).to be_empty
        end

        it "disables integration for a version if integration is disconnected" do
          @product.active_integrations << discord_integration
          @version_1.active_integrations << discord_integration

          version_integration = @version_1.base_variant_integrations.first
          product_integration = @product.product_integrations.first

          WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}").
            with(headers: { "Authorization" => "Bot #{DISCORD_BOT_TOKEN}" }).
            to_return(status: 204)

          expect do
            visit edit_link_path(@product)
            click_on "Disconnect Discord"
            expect(page).to have_button "Connect to Discord"
            save_change
          end.to change { Integration.count }.by(0)
            .and change { ProductIntegration.count }.by(0)
            .and change { BaseVariantIntegration.count }.by(0)
            .and change { @version_1.active_integrations.count }.from(1).to(0)
            .and change { @product.active_integrations.count }.from(1).to(0)

          expect(version_integration.reload.deleted?).to eq(true)
          expect(product_integration.reload.deleted?).to eq(true)
          expect(@product.reload.live_product_integrations).to be_empty
          expect(@version_1.reload.live_base_variant_integrations).to be_empty
        end

        it "disables integration for a version if integration is removed from the product" do
          @product.active_integrations << discord_integration
          @version_1.active_integrations << discord_integration

          version_integration = @version_1.base_variant_integrations.first
          product_integration = @product.product_integrations.first

          WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}").
            with(headers: { "Authorization" => "Bot #{DISCORD_BOT_TOKEN}" }).
            to_return(status: 204)

          expect do
            visit edit_link_path(@product)
            uncheck "Invite your customers to a Discord server", allow_label_click: true
            expect(page).to have_unchecked_field "Invite your customers to a Discord server"
            save_change
          end.to change { Integration.count }.by(0)
            .and change { ProductIntegration.count }.by(0)
            .and change { BaseVariantIntegration.count }.by(0)
            .and change { @version_1.active_integrations.count }.from(1).to(0)
            .and change { @product.active_integrations.count }.from(1).to(0)

          expect(version_integration.reload.deleted?).to eq(true)
          expect(product_integration.reload.deleted?).to eq(true)
          expect(@product.reload.live_product_integrations).to be_empty
          expect(@version_1.reload.live_base_variant_integrations).to be_empty
        end
      end

      context "integration for product with membership tiers" do
        before do
          @subscription_product = create(:membership_product_with_preset_tiered_pricing, user: seller)
          @tier_1 = @subscription_product.tiers[0]
          @tier_2 = @subscription_product.tiers[1]
        end

        it "shows the integration toggle if product has an integration" do
          @subscription_product.active_integrations << discord_integration
          visit edit_link_path(@subscription_product)

          expect(page).to have_text "Enable access to Discord server", count: 2
        end

        it "hides the integration toggle if product does not have an integration" do
          visit edit_link_path(@subscription_product)

          expect(page).to_not have_text "Enable access to Discord server"
        end

        it "enables integration for a tier" do
          @subscription_product.active_integrations << discord_integration

          expect do
            visit edit_link_path(@subscription_product)
            within tier_rows[1] do
              check "Enable access to Discord server", allow_label_click: true
            end
            save_change
          end.to change { Integration.count }.by(0)
            .and change { ProductIntegration.count }.by(0)
            .and change { BaseVariantIntegration.count }.by(1)

          integration = @subscription_product.active_integrations.first
          base_variant_integration = BaseVariantIntegration.first
          expect(base_variant_integration.integration).to eq(integration)
          expect(base_variant_integration.base_variant).to eq(@tier_2)
        end

        it "disables integration for a tier" do
          @subscription_product.active_integrations << discord_integration
          @tier_1.active_integrations << discord_integration

          tier_integration = @tier_1.base_variant_integrations.first

          expect do
            visit edit_link_path(@subscription_product)
            within tier_rows[0] do
              uncheck "Enable access to Discord server", allow_label_click: true
            end
            save_change
          end.to change { Integration.count }.by(0)
            .and change { ProductIntegration.count }.by(0)
            .and change { BaseVariantIntegration.count }.by(0)
            .and change { @tier_1.active_integrations.count }.from(1).to(0)

          expect(tier_integration.reload.deleted?).to eq(true)
          expect(@tier_1.reload.live_base_variant_integrations).to be_empty
        end

        it "disables integration for a tier if integration is disconnected" do
          @subscription_product.active_integrations << discord_integration
          @tier_1.active_integrations << discord_integration

          tier_integration = @tier_1.base_variant_integrations.first
          product_integration = @subscription_product.product_integrations.first

          WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}").
            with(headers: { "Authorization" => "Bot #{DISCORD_BOT_TOKEN}" }).
            to_return(status: 204)

          expect do
            visit edit_link_path(@subscription_product)
            click_on "Disconnect Discord"
            expect(page).to have_button "Connect to Discord"
            save_change
          end.to change { Integration.count }.by(0)
            .and change { ProductIntegration.count }.by(0)
            .and change { BaseVariantIntegration.count }.by(0)
            .and change { @tier_1.active_integrations.count }.from(1).to(0)
            .and change { @subscription_product.active_integrations.count }.from(1).to(0)

          expect(tier_integration.reload.deleted?).to eq(true)
          expect(product_integration.reload.deleted?).to eq(true)
          expect(@subscription_product.reload.live_product_integrations).to be_empty
          expect(@tier_1.reload.live_base_variant_integrations).to be_empty
        end

        it "disables integration for a tier if integration is removed from the product" do
          @subscription_product.active_integrations << discord_integration
          @tier_1.active_integrations << discord_integration

          tier_integration = @tier_1.base_variant_integrations.first
          product_integration = @subscription_product.product_integrations.first

          WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}").
            with(headers: { "Authorization" => "Bot #{DISCORD_BOT_TOKEN}" }).
            to_return(status: 204)

          expect do
            visit edit_link_path(@subscription_product)
            uncheck "Invite your customers to a Discord server", allow_label_click: true
            expect(page).to have_unchecked_field "Invite your customers to a Discord server"
            save_change
          end.to change { Integration.count }.by(0)
            .and change { ProductIntegration.count }.by(0)
            .and change { BaseVariantIntegration.count }.by(0)
            .and change { @tier_1.active_integrations.count }.from(1).to(0)
            .and change { @subscription_product.active_integrations.count }.from(1).to(0)

          expect(tier_integration.reload.deleted?).to eq(true)
          expect(product_integration.reload.deleted?).to eq(true)
          expect(@subscription_product.reload.live_product_integrations).to be_empty
          expect(@tier_1.reload.live_base_variant_integrations).to be_empty
        end
      end

      it "does not show the 'Enable for all versions' toggle for a physical product" do
        product = create(:physical_product, user: seller)
        create(:variant_category, link: product, title: "Color")
        create(:sku, link: product, name: "Blue - large")
        create(:sku, link: product, name: "Green - small")

        product.active_integrations << discord_integration

        visit edit_link_path(product)
        within_section "Integrations", section_element: :section do
          expect(page).to have_button("Disconnect Discord")
          expect(page).to_not have_text("Enable for all versions")
        end
      end
    end
  end
end
