# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit Integrations edit - Circle", type: :system, js: true) do
  include ProductTieredPricingHelpers
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }

  before :each do
    @product = create(:product_with_pdf_file, user: seller, size: 1024)
    @vcr_cassette_prefix = "Product Edit Integrations edit"
  end

  include_context "with switching account to user as admin for seller"

  describe "circle integration" do
    before do
      @vcr_cassette_prefix = "#{@vcr_cassette_prefix} circle integration"
    end

    it "modifies an existing integration correctly" do
      @product.active_integrations << create(:circle_integration)

      vcr_turned_on do
        VCR.use_cassette("#{@vcr_cassette_prefix} modifies an existing integration correctly") do
          visit edit_link_path(@product)
          select("Gumroad [archived]", from: "Select a community")
          select("Discover", from: "Select a space group")
          save_change
        end
      end

      integration = Integration.first
      expect(integration.community_id).to eq("3512")
      expect(integration.space_group_id).to eq("30981")
      expect(integration.keep_inactive_members).to eq(false)
    end

    it "disables integration correctly" do
      @product.active_integrations << create(:circle_integration)

      expect do
        vcr_turned_on do
          VCR.use_cassette("#{@vcr_cassette_prefix} disables integration correctly") do
            visit edit_link_path(@product)
            expect(page).to have_field("Type or paste your API token", with: GlobalConfig.get("CIRCLE_API_KEY"))
            uncheck "Invite your customers to a Circle community", allow_label_click: true
            save_change
          end
        end
      end.to change { Integration.count }.by(0)
         .and change { ProductIntegration.count }.by(0)
         .and change { @product.reload.active_integrations.count }.from(1).to(0)

      expect(ProductIntegration.first.deleted?).to eq(true)
      expect(@product.reload.live_product_integrations).to be_empty

      visit edit_link_path(@product)
      expect(page).to_not have_field("Type or paste your API token")
    end

    it "shows error on invalid api_key" do
      vcr_turned_on do
        VCR.use_cassette("#{@vcr_cassette_prefix} shows error on invalid api_key") do
          visit edit_link_path(@product)
        end
      end

      check "Invite your customers to a Circle community", allow_label_click: true
      fill_in "Type or paste your API token", with: "invalid_api_key"
      click_on("Load communities")
      expect(page).to have_text("Could not retrieve communities from Circle. Please check your API key.")
    end

    context "integration for product with multiple versions" do
      before do
        @version_category = create(:variant_category, link: @product)
        @version_1 = create(:variant, variant_category: @version_category)
        @version_2 = create(:variant, variant_category: @version_category)
        @vcr_cassette_prefix = "#{@vcr_cassette_prefix} integration for product with multiple versions"
      end

      it "shows the integration toggle if product has an integration" do
        @product.active_integrations << create(:circle_integration)

        vcr_turned_on do
          VCR.use_cassette("#{@vcr_cassette_prefix} shows the integration toggle if product has an integration") do
            visit edit_link_path(@product)
          end
        end

        expect(page).to have_text("Enable access to Circle community", count: 2)
      end

      it "hides the integration toggle if product does not have an integration" do
        vcr_turned_on do
          VCR.use_cassette("#{@vcr_cassette_prefix} hides the integration toggle if product does not have an integration") do
            visit edit_link_path(@product)
          end
        end

        expect(page).to_not have_text("Enable access to Circle community")
      end

      it "creates an integration for the product and enables integration for a newly created version" do
        product = create(:product_with_pdf_file, user: seller)

        expect do
          vcr_turned_on do
            VCR.use_cassette("#{@vcr_cassette_prefix} creates an integration for the product and enables integration for a newly created version") do
              visit edit_link_path(product)
              check "Invite your customers to a Circle community", allow_label_click: true
              fill_in "Type or paste your API token", with: GlobalConfig.get("CIRCLE_API_KEY")
              click_on("Load communities")
              select("Gumroad [archived]", from: "Select a community")
              select("Tests", from: "Select a space group")

              click_on("Add version")
              fill_in "Version name", with: "Files"

              click_on("Add version")
              within version_rows[0] do
                within version_option_rows[0] do
                  fill_in "Version name", with: "New Version"
                  check "Enable access to Circle community", allow_label_click: true
                end
              end
              save_change
            end
          end
        end.to change { Integration.count }.by(1)
           .and change { ProductIntegration.count }.by(1)
           .and change { BaseVariantIntegration.count }.by(1)

        product_integration = ProductIntegration.first
        base_variant_integration = BaseVariantIntegration.first
        integration = Integration.first

        expect(product_integration.integration).to eq(integration)
        expect(base_variant_integration.integration).to eq(integration)
        expect(base_variant_integration.base_variant.name).to eq("New Version")
        expect(product_integration.product).to eq(product)
        expect(integration.api_key).to eq(GlobalConfig.get("CIRCLE_API_KEY"))
        expect(integration.type).to eq(Integration.type_for(Integration::CIRCLE))
        expect(integration.community_id).to eq("3512")
        expect(integration.space_group_id).to eq("43576")
        expect(integration.keep_inactive_members).to eq(false)
      end

      it "disables integration for a version" do
        integration = create(:circle_integration)
        @product.active_integrations << integration
        @version_1.active_integrations << integration

        version_integration = @version_1.base_variant_integrations.first

        expect do
          vcr_turned_on do
            VCR.use_cassette("#{@vcr_cassette_prefix} disables integration for a version") do
              visit edit_link_path(@product)
              within version_rows[0] do
                within version_option_rows[0] do
                  uncheck "Enable access to Circle community", allow_label_click: true
                end
              end
              save_change
            end
          end
        end.to change { Integration.count }.by(0)
           .and change { ProductIntegration.count }.by(0)
           .and change { BaseVariantIntegration.count }.by(0)
           .and change { @version_1.active_integrations.count }.from(1).to(0)

        expect(version_integration.reload.deleted?).to eq(true)
        expect(@version_1.reload.live_base_variant_integrations).to be_empty
      end

      it "disables integration for a version if integration is removed from the product" do
        integration = create(:circle_integration)
        @product.active_integrations << integration
        @version_1.active_integrations << integration

        version_integration = @version_1.base_variant_integrations.first
        product_integration = @product.product_integrations.first

        expect do
          vcr_turned_on do
            VCR.use_cassette("#{@vcr_cassette_prefix} disables integration for a version if integration is removed from the product") do
              visit edit_link_path(@product)
              uncheck "Invite your customers to a Circle community", allow_label_click: true
              save_change
            end
          end
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
        @vcr_cassette_prefix = "#{@vcr_cassette_prefix} integration for product with membership tiers"
      end

      it "shows the integration toggle if product has an integration" do
        @subscription_product.active_integrations << create(:circle_integration)

        vcr_turned_on do
          VCR.use_cassette("#{@vcr_cassette_prefix} shows the integration toggle if product has an integration") do
            visit edit_link_path(@subscription_product)
          end
        end

        expect(page).to have_text("Enable access to Circle community", count: 2)
      end

      it "hides the integration toggle if product does not have an integration" do
        vcr_turned_on do
          VCR.use_cassette("#{@vcr_cassette_prefix} hides the integration toggle if product does not have an integration") do
            visit edit_link_path(@subscription_product)
          end
        end

        expect(page).to_not have_text("Enable access to Circle community")
      end

      it "enables integration for a tier" do
        @subscription_product.active_integrations << create(:circle_integration)

        expect do
          vcr_turned_on do
            VCR.use_cassette("#{@vcr_cassette_prefix} enables integration for a tier") do
              visit edit_link_path(@subscription_product)
              within tier_rows[1] do
                check "Enable access to Circle community", allow_label_click: true
              end
              save_change
            end
          end
        end.to change { Integration.count }.by(0)
           .and change { ProductIntegration.count }.by(0)
           .and change { BaseVariantIntegration.count }.by(1)

        integration = @subscription_product.active_integrations.first
        base_variant_integration = BaseVariantIntegration.first
        expect(base_variant_integration.integration).to eq(integration)
        expect(base_variant_integration.base_variant).to eq(@tier_2)
      end

      it "disables integration for a tier" do
        integration = create(:circle_integration)
        @subscription_product.active_integrations << integration
        @tier_1.active_integrations << integration

        tier_integration = @tier_1.base_variant_integrations.first

        expect do
          vcr_turned_on do
            VCR.use_cassette("#{@vcr_cassette_prefix} disables integration for a tier") do
              visit edit_link_path(@subscription_product)
              within tier_rows[0] do
                uncheck "Enable access to Circle community", allow_label_click: true
              end
              save_change
            end
          end
        end.to change { Integration.count }.by(0)
           .and change { ProductIntegration.count }.by(0)
           .and change { BaseVariantIntegration.count }.by(0)
           .and change { @tier_1.active_integrations.count }.from(1).to(0)

        expect(tier_integration.reload.deleted?).to eq(true)
        expect(@tier_1.reload.live_base_variant_integrations).to be_empty
      end

      it "disables integration for a tier if integration is removed from the product" do
        integration = create(:circle_integration)
        @subscription_product.active_integrations << integration
        @tier_1.active_integrations << integration

        tier_integration = @tier_1.base_variant_integrations.first
        product_integration = @subscription_product.product_integrations.first

        expect do
          vcr_turned_on do
            VCR.use_cassette("#{@vcr_cassette_prefix} disables integration for a tier if integration is removed from the product") do
              visit edit_link_path(@subscription_product)
              uncheck "Invite your customers to a Circle community", allow_label_click: true
              save_change
            end
          end
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
  end
end
