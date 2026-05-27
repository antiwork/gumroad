# frozen_string_literal: true

require "spec_helper"

describe ProductPresenter::Card do
  include Rails.application.routes.url_helpers

  let(:request) { instance_double(ActionDispatch::Request, host: "test.gumroad.com", host_with_port: "test.gumroad.com:1234", protocol: "http") }
  let(:creator) { create(:user, name: "Testy", username: "testy") }
  let(:product) { create(:product, unique_permalink: "test", name: "hello", user: creator) }

  describe "#for_web" do
    context "digital product" do
      it "returns the necessary properties for a product card" do
        data = described_class.new(product:).for_web(request:, recommended_by: "discover")

        expect(data).to eq(
          {
            id: product.external_id,
            permalink: "test",
            name: "hello",
            seller: {
              id: creator.external_id,
              name: "Testy",
              profile_url: creator.profile_url(recommended_by: "discover"),
              avatar_url: ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png"),
              is_verified: false,
            },
            description: product.plaintext_description.truncate(100),
            ratings: { count: 0, average: 0 },
            currency_code: Currency::USD,
            price_cents: 100,
            thumbnail_url: nil,
            native_type: Link::NATIVE_TYPE_DIGITAL,
            is_pay_what_you_want: false,
            is_sales_limited: false,
            duration_in_months: nil,
            recurrence: nil,
            url: product.long_url(recommended_by: "discover"),
            quantity_remaining: nil
          }
        )
      end

      it "returns the URL with the offer code" do
        data = described_class.new(product:).for_web(request:, recommended_by: "discover", offer_code: "BLACKFRIDAY2025")
        expect(data[:url]).to include("code=BLACKFRIDAY2025")
      end


      it "does not return the URL of a deleted thumbnail" do
        create(:thumbnail, product:)
        result = described_class.new(product:).for_web
        expect(result[:thumbnail_url]).to be_present

        product.thumbnail.mark_deleted!
        product.reload
        result = described_class.new(product:).for_web
        expect(result[:thumbnail_url]).to eq(nil)
      end

      it "includes description when compute_description is true by default" do
        result = described_class.new(product:).for_web

        expect(result[:description]).to eq(product.plaintext_description.truncate(100))
      end

      it "includes description when compute_description is explicitly true" do
        result = described_class.new(product:).for_web(compute_description: true)

        expect(result[:description]).to eq(product.plaintext_description.truncate(100))
      end

      it "excludes description when compute_description is false" do
        result = described_class.new(product:).for_web(compute_description: false)

        expect(result).not_to have_key(:description)
      end

      context "when compute_inventory is false" do
        let(:product) { create(:product, unique_permalink: "test", name: "hello", user: creator, max_purchase_count: 10) }

        it "sets quantity_remaining to nil and is_sales_limited to false" do
          result = described_class.new(product:).for_web(compute_inventory: false)

          expect(result[:quantity_remaining]).to be_nil
          expect(result[:is_sales_limited]).to eq(false)
        end
      end

      context "when compute_inventory is true (default)" do
        let(:product) { create(:product, unique_permalink: "test", name: "hello", user: creator, max_purchase_count: 10) }

        it "computes quantity_remaining and is_sales_limited" do
          result = described_class.new(product:).for_web(compute_inventory: true)

          expect(result[:quantity_remaining]).to eq(10)
          expect(result[:is_sales_limited]).to eq(true)
        end
      end
    end

    describe "N+1 query prevention" do
      let(:creator_with_domain) do
        creator = create(:user)
        create(:custom_domain, user: creator, domain: "creator-#{SecureRandom.hex(4)}.example.com")
        creator
      end

      def capture_queries
        queries = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
          next if payload[:name] == "SCHEMA"
          next if payload[:cached]
          sql = payload[:sql]
          next unless sql.start_with?("SELECT")
          queries << sql
        end
        begin
          yield
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end
        queries
      end

      it "does not issue per-row queries for preloaded associations" do
        # Mix of product shapes: digital, physical (skus), variant categories,
        # rentable. Each exercises a different ASSOCIATIONS branch.
        physical = create(:physical_product, user: creator_with_domain)
        digital = create(:product, user: creator_with_domain)
        variant_category = create(:variant_category, link: digital)
        create(:variant, variant_category:)
        create(:variant, variant_category:)

        ids = [physical.id, digital.id]
        loaded_products = Link.includes(*ProductPresenter::ASSOCIATIONS_FOR_CARD).where(id: ids).to_a
        # Pre-warm caches (e.g. CDN configs, currency rate fetches) so we do not
        # count one-shot setup queries as N+1.
        loaded_products.each do |product|
          described_class.new(product:).for_web(request:, show_seller: true, compute_description: false, compute_inventory: false)
        end

        queries = capture_queries do
          loaded_products = Link.includes(*ProductPresenter::ASSOCIATIONS_FOR_CARD).where(id: ids).to_a
          loaded_products.each do |product|
            described_class.new(product:).for_web(request:, show_seller: true, compute_description: false, compute_inventory: false)
          end
        end

        # If any caller drops back to `.where` on a preloaded association
        # (Antipattern 1), these patterns will fire once per product.
        # Note: `custom_domains` is intentionally NOT in this list. The
        # preload itself issues `WHERE user_id = N` when all products in
        # the fixture share one creator, which matches a naive regex —
        # but with only one creator there's no N to multiply against.
        per_row_patterns = [
          [/FROM `prices`.*WHERE `prices`\.`link_id` = \d+/, "prices"],
          [/FROM `base_variants`.*WHERE.*`link_id` = \d+/, "base_variants (skus)"],
          [/FROM `variant_categories`.*WHERE.*`link_id` = \d+/, "variant_categories"],
        ]
        per_row_patterns.each do |pattern, label|
          hits = queries.grep(pattern)
          expect(hits).to be_empty,
            "Expected no per-row #{label} queries, got #{hits.size}:\n#{hits.join("\n")}"
        end
      end

      it "does not issue per-row tier-price queries for tiered memberships" do
        recurrence_price_values = [
          { "monthly" => { enabled: true, price: 5 }, "yearly" => { enabled: true, price: 50 } },
          { "monthly" => { enabled: true, price: 10 }, "yearly" => { enabled: true, price: 100 } },
        ]
        products = Array.new(2) do
          create(:membership_product_with_preset_tiered_pricing,
                 user: creator_with_domain, recurrence_price_values:,
                 subscription_duration: "yearly")
        end

        ids = products.map(&:id)
        # Pre-warm.
        Link.includes(*ProductPresenter::ASSOCIATIONS_FOR_CARD).where(id: ids).to_a.each do |product|
          described_class.new(product:).for_web(request:, show_seller: true, compute_description: false, compute_inventory: false)
        end

        queries = capture_queries do
          loaded = Link.includes(*ProductPresenter::ASSOCIATIONS_FOR_CARD).where(id: ids).to_a
          loaded.each do |product|
            described_class.new(product:).for_web(request:, show_seller: true, compute_description: false, compute_inventory: false)
          end
        end

        # Antipattern 6: per-row VariantPrice / customizable_price lookups
        # under tiers. The preload `tiers: :alive_prices` plus the
        # `loaded?` guards on Link#has_customizable_price_option? and
        # Product::Prices#lowest_tier_price should batch these into the
        # initial `WHERE variant_id IN (...)` and never fire per-row.
        per_row_patterns = [
          [/FROM `prices` WHERE `prices`\.`variant_id` = \d+/, "tier prices (variant_id = N)"],
          [/FROM `base_variants`.*customizable_price/, "base_variants customizable_price"],
        ]
        per_row_patterns.each do |pattern, label|
          hits = queries.grep(pattern)
          expect(hits).to be_empty,
            "Expected no per-row #{label} queries, got #{hits.size}:\n#{hits.join("\n")}"
        end
      end
    end

    context "membership product" do
      let(:product) do
        recurrence_price_values = [
          {
            "monthly" => { enabled: true, price: 10 },
            "yearly" => { enabled: true, price: 100 }
          },
          {
            "monthly" => { enabled: true, price: 2.99 },
            "yearly" => { enabled: true, price: 19.99 }
          }
        ]
        create(:membership_product_with_preset_tiered_pricing, user: creator, recurrence_price_values:, subscription_duration: "yearly")
      end

      it "includes the lowest tier price for the default subscription duration" do
        data = described_class.new(product:).for_web
        expect(data[:price_cents]).to eq 19_99
      end
    end

    context "with default offer code" do
      let(:product_with_offer_code) { create(:product, unique_permalink: "test_offer", name: "hello with offer", user: creator, price_cents: 10_00) }
      let(:offer_code) { create(:offer_code, user: creator, products: [product_with_offer_code], amount_percentage: 10, amount_cents: nil) }

      before do
        product_with_offer_code.update!(default_offer_code: offer_code)
      end

      it "applies the discount to the price_cents" do
        data = described_class.new(product: product_with_offer_code).for_web
        expect(data[:price_cents]).to eq 9_00 # 1000 - 10% discount = 900
        expect(data[:original_price_cents]).to eq 10_00
      end

      it "does not show original price for zero discount" do
        offer_code.update!(amount_percentage: 0)
        data = described_class.new(product: product_with_offer_code).for_web
        expect(data[:price_cents]).to eq 10_00
        expect(data).not_to have_key(:original_price_cents)
      end

      it "does not apply the discount when the offer code has expired" do
        offer_code.update!(valid_at: 2.days.ago, expires_at: 1.day.ago)
        data = described_class.new(product: product_with_offer_code).for_web
        expect(data[:price_cents]).to eq 10_00
        expect(data).not_to have_key(:original_price_cents)
      end

      it "does not apply the discount when the offer code is not yet active" do
        offer_code.update!(valid_at: 1.day.from_now, expires_at: 2.days.from_now)
        data = described_class.new(product: product_with_offer_code).for_web
        expect(data[:price_cents]).to eq 10_00
        expect(data).not_to have_key(:original_price_cents)
      end

      it "does not apply existing-customer-only discounts to anonymous cards" do
        offer_code.update!(existing_customers_only: true, ownership_products: [product_with_offer_code])

        data = described_class.new(product: product_with_offer_code).for_web
        expect(data[:price_cents]).to eq 10_00
        expect(data).not_to have_key(:original_price_cents)
      end
    end
  end

  describe "#for_email" do
    it "returns the necessary properties for an email product card" do
      expect(described_class.new(product:).for_email).to eq(
        {
          name: product.name,
          thumbnail_url: ActionController::Base.helpers.image_url("native_types/thumbnails/digital.png"),
          url: short_link_url(product.general_permalink, host: "http://#{creator.username}.test.gumroad.com:31337"),
          seller: {
            name: creator.name,
            profile_url: creator.profile_url,
            avatar_url: ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png"),
          },
        }
      )
    end
  end
end
