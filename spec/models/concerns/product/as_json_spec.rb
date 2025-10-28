# frozen_string_literal: true

require "spec_helper"

describe Product::AsJson, :vcr do
  describe "as_json method" do
    before do
      @product = create(:product, name: "some link", require_shipping: true)
    end

    it "returns the correct has for default (public)" do
      expect(@product.as_json.key?("name")).to be(true)
      expect(@product.as_json.key?("require_shipping")).to be(true)
      expect(@product.as_json.key?("url")).to be(false)
    end

    context "for api" do
      context "[:view_public] scope" do
        it "returns the correct hash" do
          json = @product.as_json(api_scopes: ["view_public"])
          %w[
            name description require_shipping preview_url url
            max_purchase_count custom_receipt customizable_price
            custom_summary deleted custom_fields
          ].each do |key|
            expect(json.key?(key)).to be(true)
          end
        end

        it "includes pricing data for a tiered membership product" do
          product = create(:membership_product_with_preset_tiered_pricing)

          json = product.as_json(api_scopes: ["view_public"])

          expect(json["is_tiered_membership"]).to eq true
          expect(json["recurrences"]).to eq ["monthly"]
          tiers_json = json["variants"][0][:options]
          tiers_json.map do |tier_json|
            expect(tier_json[:is_pay_what_you_want]).to eq false
            expect(tier_json[:recurrence_prices].keys).to eq ["monthly"]
            expect(tier_json[:recurrence_prices]["monthly"].keys).to match_array [:price_cents, :suggested_price_cents]
          end
        end

        it "returns thumbnail_url information" do
          thumbnail = create(:thumbnail)
          product = thumbnail.product

          json = product.as_json(api_scopes: ["view_public"])
          expect(json["thumbnail_url"]).to eq thumbnail.url
        end

        it "returns tags" do
          @product.tag!("one")
          @product.tag!("two")

          json = @product.as_json(api_scopes: ["view_public"])
          expect(json["tags"]).to contain_exactly("one", "two")
        end
      end
    end

    it "returns the correct text for custom_summary" do
      @product.save_custom_summary("test")
      json = @product.as_json(api_scopes: ["view_public"])
      expect(json["custom_summary"]).to eq "test"
      @product.save_custom_summary(nil)
      json = @product.as_json(api_scopes: ["view_public"])
      expect(json["custom_summary"]).to eq nil
      @product.save_custom_summary("")
      json = @product.as_json(api_scopes: ["view_public"])
      expect(json["custom_summary"]).to eq ""
    end

    it "returns the correct values for custom_fields" do
      json = @product.as_json(api_scopes: ["view_public"])
      expect(json["custom_fields"]).to eq []

      @product.custom_fields << create(:custom_field, name: "I'm custom!")
      json = @product.as_json(api_scopes: ["view_public"])
      expect(json["custom_fields"]).to eq [
        { id: @product.custom_fields.last.external_id, type: "text", name: "I'm custom!", required: false, collect_per_product: false },
      ].as_json
    end

    it "returns the correct hash for api, :view_public,:edit_products" do
      json = @product.as_json(api_scopes: %w[view_public edit_products])
      %w[
        name description require_shipping preview_url url
        max_purchase_count custom_receipt customizable_price
        custom_summary deleted custom_fields
      ].each do |key|
        expect(json.key?(key)).to be(true)
      end
      %w[
        sales_count sales_usd_cents view_count
      ].each do |key|
        expect(json.key?(key)).to be(false)
      end
    end

    it "returns the correct value for max_purchase_count if it is not set by the user" do
      expect(@product.as_json(api_scopes: %w[view_public edit_products])["max_purchase_count"]).to be(nil)
    end

    it "returns the correct value for max_purchase_count if it is set by the user" do
      @product.update(max_purchase_count: 10)
      expect(@product.reload.as_json(api_scopes: %w[view_public edit_products])["max_purchase_count"]).to eq 10
    end

    it "returns the correct hash for api, :view_sales" do
      %w[name description require_shipping url file_info sales_count sales_usd_cents].each do |key|
        expect(@product.as_json(api_scopes: ["view_sales"]).key?(key)).to be(true)
      end
    end

    it "includes the preorder_link information for an unreleased link" do
      @product.update(is_in_preorder_state: true)
      @preorder_link = create(:preorder_link, link: @product, release_at: 2.days.from_now)
      link_json = @product.as_json
      expect(link_json["is_preorder"]).to be(true)
      expect(link_json["is_in_preorder_state"]).to be(true)
      expect(link_json["release_at"].present?).to be(true)
    end

    it "includes the preorder_link information for a released link" do
      @preorder_link = create(:preorder_link, link: @product, release_at: 2.days.from_now) # can't create a preorder with a release_at in the past
      @preorder_link.update(release_at: Date.yesterday)
      link_json = @product.as_json
      expect(link_json["is_preorder"]).to be(true)
      expect(link_json["is_in_preorder_state"]).to be(false)
      expect(link_json["release_at"].present?).to be(true)
    end

    it "includes deprecated `custom_delivery_url` attribute" do
      expect(@product.as_json).to include("custom_delivery_url" => nil)
    end

    it "includes deprecated `url` attribute" do
      expect(@product.as_json(api_scopes: %w[view_public edit_products])).to include("url" => nil)
    end

    describe "as_json_for_api" do
      context "for a product with variants" do
        let(:product) { create(:product) }
        let(:category) { create(:variant_category, link: product, title: "Color") }
        let!(:blue_variant) { create(:variant, variant_category: category, name: "Blue") }
        let!(:green_variant) { create(:variant, variant_category: category, name: "Green") }

        it "returns deprecated `url` attribute" do
          result = product.as_json(api_scopes: %w[view_public edit_products])
          expect(result.dig("variants", 0, :options)).to include(
            hash_including(name: "Blue", url: nil),
            hash_including(name: "Green", url: nil),
          )
        end
      end

      context "when user has purchasing_power_parity_enabled" do
        before do
          @product.user.update!(purchasing_power_parity_enabled: true)
          @product.update!(price_cents: 300)
          PurchasingPowerParityService.new.set_factor("MX", 0.5)
        end

        it "includes PPP prices for every country" do
          result = @product.as_json(api_scopes: %w[view_sales])
          expect(result["purchasing_power_parity_prices"].keys).to eq(Compliance::Countries.mapping.keys)
          expect(result["purchasing_power_parity_prices"]["MX"]).to eq(150)
        end

        context "when injecting a preloaded factors" do
          it "includes PPP prices for every country without calling PurchasingPowerParityService" do
            expect_any_instance_of(PurchasingPowerParityService).not_to receive(:get_all_countries_factors)
            result = @product.as_json(
              api_scopes: %w[view_sales],
              preloaded_ppp_factors: { "MX" => 0.8, "CA" => 0.9 }
            )
            expect(result["purchasing_power_parity_prices"]).to eq("MX" => 240, "CA" => 270)
          end
        end
      end

      context "when user has purchasing_power_parity_enabled and product has purchasing_power_parity_disabled" do
        before do
          @product.user.update!(purchasing_power_parity_enabled: true)
          @product.update!(price_cents: 300, purchasing_power_parity_disabled: true)
          PurchasingPowerParityService.new.set_factor("MX", 0.5)
        end

        it "doesn't include PPP prices for every country" do
          result = @product.as_json(api_scopes: %w[view_sales])
          expect(result["purchasing_power_parity_prices"]).to be_nil
        end
      end

      context "when api_scopes includes 'view_sales'", :sidekiq_inline, :elasticsearch_wait_for_refresh do
        it "includes sales data" do
          product = create(:product)
          create(:purchase, link: product)
          create(:failed_purchase, link: product)

          result = product.as_json(api_scopes: %w[view_sales])
          expect(result["sales_count"]).to eq(1)
          expect(result["sales_usd_cents"]).to eq(100)
        end
      end
    end

    describe "as_json_for_mobile_api" do
      it "returns proper json for a product" do
        link = create(:product, preview: fixture_file_upload("kFDzu.png", "image/png"), content_updated_at: Time.current)
        json_hash = link.as_json(mobile: true)
        %w[name description unique_permalink created_at updated_at content_updated_at preview_url].each do |attr|
          attr = attr.to_sym unless %w[name description unique_permalink].include?(attr)
          expect(json_hash[attr]).to eq link.send(attr)
        end
        expect(json_hash[:preview_oembed_url]).to eq ""
        expect(json_hash[:preview_height]).to eq 210
        expect(json_hash[:preview_width]).to eq 670
        expect(json_hash[:has_rich_content]).to eq true
      end

      it "returns thumbnail information" do
        thumbnail = create(:thumbnail)
        product = thumbnail.product

        json_hash = product.as_json(mobile: true)
        expect(json_hash[:thumbnail_url]).to eq thumbnail.url
      end

      it "returns creator info for a product" do
        user = create(:named_user, :with_avatar)

        product = create(:product, user:)
        json_hash = product.as_json(mobile: true)
        expect(json_hash[:creator_name]).to eq user.name_or_username
        expect(json_hash[:creator_profile_picture_url]).to eq user.avatar_url
        expect(json_hash[:creator_profile_url]).to eq user.profile_url
      end

      it "returns a blank preview_url if there is no preview for the product" do
        link = create(:product, preview: fixture_file_upload("kFDzu.png", "image/png"))
        link.asset_previews.each { |preview| preview.update(deleted_at: Time.current) }
        json_hash = link.as_json(mobile: true)
        expect(json_hash[:preview_url]).to eq ""
      end

      it "returns proper json for a product with a youtube preview" do
        link = create(:product, preview_url: "https://youtu.be/blSl487coFg")
        expect(link.as_json(mobile: true)[:preview_oembed_url]).to eq("https://www.youtube.com/embed/blSl487coFg?feature=oembed&showinfo=0&controls=0&rel=0&enablejsapi=1")
      end

      it "returns proper json for a product with a soundcloud preview" do
        link = create(:product, preview_url: "https://soundcloud.com/cade-turner/cade-turner-symphony-of-light", user: create(:user, username: "elliomax"))
        json_hash = link.as_json(mobile: true)
        %w[name description unique_permalink created_at updated_at].each do |attr|
          attr = attr.to_sym unless %w[name description unique_permalink].include?(attr)
          expect(json_hash[attr]).to eq link.send(attr)
        end
        expect(json_hash[:creator_name]).to eq "elliomax"
        expect(json_hash[:preview_url]).to eq "https://i1.sndcdn.com/artworks-000053047348-b62qv1-t500x500.jpg"
        expect(json_hash[:preview_oembed_url]).to eq(
          "https://w.soundcloud.com/player/?visual=true&url=https%3A%2F%2Fapi.soundcloud.com%2Ftracks%2F101276036&auto_play=false" \
          "&show_artwork=false&show_comments=false&buying=false&sharing=false&download=false&show_playcount=false&show_user=false&liking=false&maxwidth=670"
        )
      end

      it "returns proper json for a product with a vimeo preview" do
        link = create(:product, preview_url: "https://vimeo.com/30698649", user: create(:user, username: "elliomax"))
        json_hash = link.as_json(mobile: true)
        %w[name description unique_permalink created_at updated_at].each do |attr|
          attr = attr.to_sym unless %w[name description unique_permalink].include?(attr)
          expect(json_hash[attr]).to eq link.send(attr)
        end
        expect(json_hash[:creator_name]).to eq "elliomax"
        expect(json_hash[:preview_url]).to eq "https://i.vimeocdn.com/video/212645621-df44232fa6e6b46afd643f7e733a7bfe2cc7cb97486158998bfbc601231722e9-d_640?region=us"
        expect(json_hash[:preview_oembed_url]).to eq "https://player.vimeo.com/video/30698649?app_id=122963"
      end

      it "does not return preview heights less than 204 pixels" do
        link = create(:product, preview: fixture_file_upload("kFDzu.png", "image/png"))
        allow_any_instance_of(Link).to receive(:preview_height).and_return(100)
        json_hash = link.as_json(mobile: true)
        %w[name description unique_permalink created_at updated_at preview_url].each do |attr|
          attr = attr.to_sym unless %w[name description unique_permalink].include?(attr)
          expect(json_hash[attr]).to eq link.send(attr)
        end
        expect(json_hash[:creator_name]).to eq link.user.username
        expect(json_hash[:preview_oembed_url]).to eq ""
        expect(json_hash[:preview_height]).to eq 0
        expect(json_hash[:preview_width]).to eq 670
      end

      it "returns 'has_rich_content' true" do
        product = create(:product)

        expect(product.as_json(mobile: true)[:has_rich_content]).to eq(true)
      end
    end

    describe "as_json_variant_details_only" do
      context "for a product with variants" do
        it "includes a hash of variants data under 'categories'" do
          circle_integration = create(:circle_integration)
          discord_integration = create(:discord_integration)
          product = create(:product, active_integrations: [circle_integration, discord_integration])
          category = create(:variant_category, link: product, title: "Color")
          blue_variant = create(:variant, variant_category: category, name: "Blue", active_integrations: [circle_integration])
          green_variant = create(:variant, variant_category: category, name: "Green", active_integrations: [discord_integration])
          result = product.as_json(variant_details_only: true)

          expect(result).to eq(
            categories: {
              category.external_id => {
                title: "Color",
                options: {
                  blue_variant.external_id => {
                    "option" => blue_variant.name,
                    "name" => blue_variant.name,
                    "description" => nil,
                    "id" => blue_variant.external_id,
                    "max_purchase_count" => nil,
                    "price_difference_cents" => 0,
                    "price_difference_in_currency_units" => 0.0,
                    "showing" => false,
                    "quantity_left" => nil,
                    "amount_left_title" => "",
                    "displayable" => blue_variant.name,
                    "sold_out" => false,
                    "price_difference" => "0",
                    "currency_symbol" => "$",
                    "product_files_ids" => [],
                    "integrations" => { "circle" => true, "discord" => false, "zoom" => false, "google_calendar" => false },
                  },
                  green_variant.external_id => {
                    "option" => green_variant.name,
                    "name" => green_variant.name,
                    "description" => nil,
                    "id" => green_variant.external_id,
                    "max_purchase_count" => nil,
                    "price_difference_cents" => 0,
                    "price_difference_in_currency_units" => 0.0,
                    "showing" => false,
                    "quantity_left" => nil,
                    "amount_left_title" => "",
                    "displayable" => green_variant.name,
                    "sold_out" => false,
                    "price_difference" => "0",
                    "currency_symbol" => "$",
                    "product_files_ids" => [],
                    "integrations" => { "circle" => false, "discord" => true, "zoom" => false, "google_calendar" => false },
                  }
                }
              }
            },
            skus: {},
            skus_enabled: false
          )
        end

        it "sets category title to \"Version\" if there is no title" do
          product = create(:product)
          category = create(:variant_category, link: product, title: "")
          result = product.as_json(variant_details_only: true)

          expect(result).to eq(
            categories: {
              category.external_id => {
                title: "Version",
                options: {}
              }
            },
            skus: {},
            skus_enabled: false
          )
        end
      end

      context "for a tiered membership" do
        it "includes a hash of tier data under 'categories'" do
          circle_integration = create(:circle_integration)
          discord_integration = create(:discord_integration)
          product = create(:membership_product, name: "My Membership", active_integrations: [circle_integration, discord_integration])
          category = product.tier_category
          first_tier = category.variants.first
          first_tier.active_integrations << circle_integration
          second_tier = create(:variant, variant_category: category, name: "2nd Tier", active_integrations: [discord_integration])

          result = product.as_json(variant_details_only: true)

          expect(result).to eq(
            categories: {
              category.external_id => {
                title: "Tier",
                options: {
                  first_tier.external_id => {
                    "option" => "Untitled",
                    "name" => "My Membership",
                    "description" => nil,
                    "id" => first_tier.external_id,
                    "max_purchase_count" => nil,
                    "price_difference_cents" => nil,
                    "price_difference_in_currency_units" => 0.0,
                    "showing" => true,
                    "quantity_left" => nil,
                    "amount_left_title" => "",
                    "displayable" => "Untitled",
                    "sold_out" => false,
                    "price_difference" => 0,
                    "currency_symbol" => "$",
                    "product_files_ids" => [],
                    "is_customizable_price" => false,
                    "recurrence_price_values" => {
                      "monthly" => { enabled: true, price: "1", price_cents: 100, suggested_price_cents: nil },
                      "quarterly" => { enabled: false },
                      "biannually" => { enabled: false },
                      "yearly" => { enabled: false },
                      "every_two_years" => { enabled: false },
                    },
                    "integrations" => { "circle" => true, "discord" => false, "zoom" => false, "google_calendar" => false },
                  },
                  second_tier.external_id => {
                    "option" => second_tier.name,
                    "name" => second_tier.name,
                    "description" => nil,
                    "id" => second_tier.external_id,
                    "max_purchase_count" => nil,
                    "price_difference_cents" => 0,
                    "price_difference_in_currency_units" => 0.0,
                    "showing" => false,
                    "quantity_left" => nil,
                    "amount_left_title" => "",
                    "displayable" => second_tier.name,
                    "sold_out" => false,
                    "price_difference" => "0",
                    "currency_symbol" => "$",
                    "product_files_ids" => [],
                    "is_customizable_price" => false,
                    "recurrence_price_values" => {
                      "monthly" => { enabled: false },
                      "quarterly" => { enabled: false },
                      "biannually" => { enabled: false },
                      "yearly" => { enabled: false },
                      "every_two_years" => { enabled: false },
                    },
                    "integrations" => { "circle" => false, "discord" => true, "zoom" => false, "google_calendar" => false },
                  }
                }
              }
            },
            skus: {},
            skus_enabled: false
          )
        end
      end

      context "for a product with skus_enabled" do
        it "includes a hash of SKUs data under 'skus'" do
          product = create(:physical_product)
          category_1 = create(:variant_category, link: product, title: "Color")
          category_2 = create(:variant_category, link: product, title: "Size")
          skus_title = "#{category_1.title} - #{category_2.title}"
          sku = create(:sku, link: product, name: "Blue - large")

          result = product.as_json(variant_details_only: true)

          expect(result).to eq(
            categories: {
              category_1.external_id => {
                title: category_1.title,
                options: {}
              },
              category_2.external_id => {
                title: category_2.title,
                options: {}
              }
            },
            skus: {
              sku.external_id => {
                "option" => sku.name,
                "name" => sku.name,
                "description" => nil,
                "id" => sku.external_id,
                "max_purchase_count" => nil,
                "price_difference_cents" => 0,
                "price_difference_in_currency_units" => 0.0,
                "showing" => false,
                "quantity_left" => nil,
                "amount_left_title" => "",
                "displayable" => sku.name,
                "sold_out" => false,
                "price_difference" => "0",
                "currency_symbol" => "$",
                "product_files_ids" => [],
                "integrations" => { "circle" => false, "discord" => false, "zoom" => false, "google_calendar" => false },
              }
            },
            skus_title:,
            skus_enabled: true
          )
        end
      end

      context "for a product without variants" do
        it "returns empty objects" do
          product = create(:product)

          result = product.as_json(variant_details_only: true)

          expect(result).to eq(
            categories: {},
            skus: {},
            skus_enabled: false
          )
        end
      end
    end

    describe "recommendable attribute" do
      it "returns true if the product is recommendable" do
        product = create(:product, :recommendable)
        json = product.as_json
        expect(json["recommendable"]).to eq true
      end

      it "returns false otherwise" do
        product = create(:product)
        json = product.as_json
        expect(json["recommendable"]).to eq false
      end
    end

    describe "rated_as_adult attribute" do
      it "returns true if the product is rated_as_adult" do
        product = create(:product, is_adult: true)
        json = product.as_json
        expect(json["rated_as_adult"]).to eq true
      end

      it "returns false otherwise" do
        product = create(:product)
        json = product.as_json
        expect(json["rated_as_adult"]).to eq false
      end
    end
  end
end
