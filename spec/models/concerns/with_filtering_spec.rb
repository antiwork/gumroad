# frozen_string_literal: true

require "spec_helper"

describe WithFiltering do
  describe "scopes" do
    describe "abandoned_cart_type" do
      it "returns only installments with the 'abandoned_cart' type" do
        abandoned_cart_installment = create(:installment, installment_type: Installment::ABANDONED_CART_TYPE)
        create(:installment)
        expect(Installment.abandoned_cart_type).to eq([abandoned_cart_installment])
      end

      it "returns only workflows with the 'abandoned_cart' type" do
        abandoned_cart_workflow = create(:abandoned_cart_workflow)
        create(:workflow)
        expect(Workflow.abandoned_cart_type).to eq([abandoned_cart_workflow])
      end
    end
  end
  describe "#purchase_passes_filters" do
    context "for created filters" do
      before do
        @product = create(:product)
        @purchase = create(:purchase, link: @product)
        @old_purchase = create(:purchase, link: @product, created_at: 1.month.ago)
      end

      context "when created_before filter is set" do
        before do
          @post = create(:seller_installment, seller: @product.user, json_data: { created_before: 1.day.ago })
        end

        it "returns true for purchase older than the created_before date" do
          expect(@post.purchase_passes_filters(@old_purchase)).to eq(true)
        end

        it "returns false for purchase newer than the created_before date" do
          expect(@post.purchase_passes_filters(@purchase)).to eq(false)
        end
      end

      context "when created_after filter is set" do
        before do
          @post = create(:seller_installment, seller: @product.user, json_data: { created_after: 1.day.ago })
        end

        it "returns true for purchase newer than the created_after date" do
          expect(@post.purchase_passes_filters(@purchase)).to eq(true)
        end

        it "returns false for purchase older than the created_after date" do
          expect(@post.purchase_passes_filters(@old_purchase)).to eq(false)
        end
      end

      context "when created_before and created_after filters are set" do
        before do
          @purchase_2 = create(:purchase, link: @product, created_at: 1.week.ago)
          @post = create(:seller_installment, seller: @product.user, json_data: { created_after: 2.weeks.ago, created_before: 1.day.ago })
        end

        it "returns true for purchase within the created dates" do
          expect(@post.purchase_passes_filters(@purchase_2)).to eq(true)
        end

        it "returns false for purchases outside the created dates" do
          expect(@post.purchase_passes_filters(@purchase)).to eq(false)
          expect(@post.purchase_passes_filters(@old_purchase)).to eq(false)
        end
      end
    end

    context "for price filters" do
      before do
        @product = create(:product)
        @small_purchase = create(:purchase, link: @product, price_cents: 50)
        @medium_purchase = create(:purchase, link: @product, price_cents: 500)
        @big_purchase = create(:purchase, link: @product, price_cents: 1000)
      end

      context "when paid_more_than_cents filter is set" do
        before do
          @post = create(:seller_installment, seller: @product.user, json_data: { paid_more_than_cents: 100 })
        end

        it "returns true for purchases higher than the paid_more_than_cents filter" do
          expect(@post.purchase_passes_filters(@medium_purchase)).to eq(true)
          expect(@post.purchase_passes_filters(@big_purchase)).to eq(true)
        end

        it "returns false for purchases lower than the paid_more_than_cents filter" do
          expect(@post.purchase_passes_filters(@small_purchase)).to eq(false)
        end
      end

      context "when paid_less_than_cents filter is set" do
        before do
          @post = create(:seller_installment, seller: @product.user, json_data: { paid_less_than_cents: 100 })
        end

        it "returns false for purchases higher than the paid_more_than_cents filter" do
          expect(@post.purchase_passes_filters(@medium_purchase)).to eq(false)
          expect(@post.purchase_passes_filters(@big_purchase)).to eq(false)
        end

        it "returns true for purchases lower than the paid_more_than_cents filter" do
          expect(@post.purchase_passes_filters(@small_purchase)).to eq(true)
        end
      end

      context "when paid_more_than_cents and paid_less_than_cents filters are set" do
        before do
          @post = create(:seller_installment, seller: @product.user, json_data: { paid_more_than_cents: 100, paid_less_than_cents: 500 })
        end

        it "returns true for purchase within the price range" do
          expect(@post.purchase_passes_filters(@medium_purchase)).to eq(true)
        end

        it "returns false for purchases outside the price range" do
          expect(@post.purchase_passes_filters(@small_purchase)).to eq(false)
          expect(@post.purchase_passes_filters(@big_purchase)).to eq(false)
        end
      end
    end

    context "when bought from country filter is set" do
      before do
        @product = create(:product)
        @us_purchase_1 = create(:purchase, link: @product, country: "United States")
        @us_purchase_2 = create(:purchase, link: @product, ip_country: "United States")
        @non_us_purchase = create(:purchase, link: @product, price_cents: 1000, country: "Canada")
        @post = create(:seller_installment, seller: @product.user, json_data: { bought_from: "United States" })
      end

      it "returns true for purchases from selected bought_from country filter" do
        expect(@post.purchase_passes_filters(@us_purchase_1)).to eq(true)
        expect(@post.purchase_passes_filters(@us_purchase_2)).to eq(true)
      end

      it "returns false for purchase not matching the bought_from country filter" do
        expect(@post.purchase_passes_filters(@non_us_purchase)).to eq(false)
      end
    end

    context "when active customers only filter is set" do
      before do
        @product = create(:membership_product)
        @active_purchase = create(:membership_purchase, link: @product)
        @cancelled_purchase = create(:membership_purchase, link: @product)
        @cancelled_purchase.subscription.update!(cancelled_at: 1.day.ago)
        @post = create(:seller_installment, seller: @product.user, json_data: { active_customers_only: true })
      end

      it "returns true for purchases from active customers" do
        expect(@post.purchase_passes_filters(@active_purchase)).to eq(true)
      end

      it "returns false for purchases from cancelled customers" do
        expect(@post.purchase_passes_filters(@cancelled_purchase)).to eq(false)
      end

      it "returns true for active and cancelled purchases when the active customers only filter is not set" do
        post = create(:seller_installment, seller: @product.user)

        expect(post.purchase_passes_filters(@active_purchase)).to eq(true)
        expect(post.purchase_passes_filters(@cancelled_purchase)).to eq(true)
      end
    end

    context "when minimum license uses filter is set" do
      before do
        @product = create(:product)
        @qualified_purchase = create(:purchase, :with_license, link: @product)
        @qualified_purchase.license.update!(uses: 3)
        @underused_purchase = create(:purchase, :with_license, link: @product)
        @underused_purchase.license.update!(uses: 2)
        @post = create(:seller_installment, seller: @product.user, json_data: { minimum_license_uses: 3 })
      end

      it "returns true for purchases with license uses at the threshold" do
        expect(@post.purchase_passes_filters(@qualified_purchase)).to eq(true)
      end

      it "returns false for purchases with license uses below the threshold" do
        expect(@post.purchase_passes_filters(@underused_purchase)).to eq(false)
      end

      it "returns true for purchases above and below the threshold when the minimum license uses filter is not set" do
        post = create(:seller_installment, seller: @product.user)

        expect(post.purchase_passes_filters(@qualified_purchase)).to eq(true)
        expect(post.purchase_passes_filters(@underused_purchase)).to eq(true)
      end
    end

    describe "bought products and variants filters" do
      before do
        @product = create(:product)
        @variant = create(:variant, variant_category: create(:variant_category, link: @product))
        @purchase = create(:purchase, link: @product)
      end

      describe "bought products only" do
        it "returns true if the purchased product is included in the filter" do
          post = create(:seller_installment, seller: @product.user, json_data: { bought_products: [@product.unique_permalink] })
          expect(post.purchase_passes_filters(@purchase)).to eq true
        end

        it "returns false if the purchased product is not included in the filter" do
          post = create(:seller_installment, seller: @product.user, json_data: { bought_products: [create(:product).unique_permalink] })
          expect(post.purchase_passes_filters(@purchase)).to eq false
        end
      end

      describe "bought variants only" do
        before do
          @purchase.variant_attributes = [@variant]
        end

        it "returns true if the purchased variant is included in the filter" do
          post = create(:seller_installment, seller: @product.user, json_data: { bought_variants: [@variant.external_id] })
          expect(post.purchase_passes_filters(@purchase)).to eq true
        end

        it "returns false if the purchased variant is not included in the filter" do
          post = create(:seller_installment, seller: @product.user, json_data: { bought_variants: [create(:variant).external_id] })
          expect(post.purchase_passes_filters(@purchase)).to eq false
        end
      end

      describe "bought products and variants" do
        it "returns true if the purchased product is included in the filter" do
          post = create(:seller_installment, seller: @product.user, json_data: { bought_products: [@product.unique_permalink], bought_variants: [create(:variant).external_id] })
          expect(post.purchase_passes_filters(@purchase)).to eq true
        end

        it "returns false if the purchased product is not included in the filter" do
          post = create(:seller_installment, seller: @product.user, json_data: { bought_products: [create(:product).unique_permalink], bought_variants: [create(:variant).external_id] })
          expect(post.purchase_passes_filters(@purchase)).to eq false
        end

        it "returns true if the purchased variant is included in the filter" do
          @purchase.variant_attributes = [@variant]
          post = create(:seller_installment, seller: @product.user, json_data: { bought_products: [create(:product).unique_permalink], bought_variants: [@variant.external_id] })
          expect(post.purchase_passes_filters(@purchase)).to eq true
        end

        it "returns false if the purchased variant is not included in the filter" do
          @purchase.variant_attributes = [@variant]
          post = create(:seller_installment, seller: @product.user, json_data: { bought_products: [create(:product).unique_permalink], bought_variants: [create(:variant).external_id] })
          expect(post.purchase_passes_filters(@purchase)).to eq false
        end
      end
    end

    describe "not bought filters" do
      let(:post) { create(:seller_installment, seller: @product.user, json_data: { not_bought_products:, not_bought_variants: }) }

      before do
        @product = create(:product)
        @variant = create(:variant, variant_category: create(:variant_category, link: @product))
        @purchase = create(:purchase, link: @product)
      end

      describe "not bought products only" do
        context "when the purchased product is not included in the filter" do
          let(:not_bought_products) { [create(:product).unique_permalink] }
          let(:not_bought_variants) { [] }

          it "returns true" do
            expect(post.purchase_passes_filters(@purchase)).to eq true
          end
        end

        context "when the purchased product is included in the filter" do
          let(:not_bought_products) { [@product.unique_permalink] }
          let(:not_bought_variants) { [] }

          it "returns false" do
            expect(post.purchase_passes_filters(@purchase)).to eq false
          end
        end
      end

      describe "not bought variants only" do
        before do
          @purchase.variant_attributes = [@variant]
        end

        context "when the purchased variant is not included in the filter" do
          let(:not_bought_products) { nil }
          let(:not_bought_variants) { [@variant.external_id] }

          it "returns false" do
            expect(post.purchase_passes_filters(@purchase)).to eq false
          end
        end

        context "when the purchased variant is not included in the filter" do
          let(:not_bought_products) { [] }
          let(:not_bought_variants) { [create(:variant).external_id] }

          it "returns true" do
            expect(post.purchase_passes_filters(@purchase)).to eq true
          end
        end

        context "when the probe falls back to SQL" do
          let(:not_bought_products) { [] }
          let(:not_bought_variants) { [@variant.external_id] }

          it "filters each half of the variant subquery by the buyer's email" do
            probe_sql = nil
            callback = ->(*, payload) { probe_sql = payload[:sql] if payload[:sql].include?(" UNION ") }
            ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
              post.purchase_passes_filters(@purchase)
            end

            branches = probe_sql[/SELECT id FROM \((.*)\) AS t_purchases/, 1].split(" UNION ")
            expect(branches.size).to eq(2)
            expect(branches).to all(include("`purchases`.`email` = #{Purchase.connection.quote(@purchase.email)}"))
          end
        end
      end

      describe "not bought products and variants" do
        context "when the purchased product is included in the filter" do
          let(:not_bought_products) { [@product.unique_permalink] }
          let(:not_bought_variants) { [create(:variant).external_id] }

          it "returns false" do
            expect(post.purchase_passes_filters(@purchase)).to eq false
          end
        end

        context "when the purchased product is not included in the filter" do
          let(:not_bought_products) { [create(:product).unique_permalink] }
          let(:not_bought_variants) { [create(:variant).external_id] }

          it "returns true" do
            expect(post.purchase_passes_filters(@purchase)).to eq true
          end
        end

        context "when the purchased variant is included in the filter" do
          let(:not_bought_products) { [create(:product).unique_permalink] }
          let(:not_bought_variants) { [@variant.external_id] }

          it "returns false" do
            @purchase.variant_attributes = [@variant]
            expect(post.purchase_passes_filters(@purchase)).to eq false
          end
        end

        context "when the purchased variant is not included in the filter" do
          let(:not_bought_products) { [create(:product).unique_permalink] }
          let(:not_bought_variants) { [create(:variant).external_id] }

          it "returns true" do
            @purchase.variant_attributes = [@variant]
            expect(post.purchase_passes_filters(@purchase)).to eq true
          end
        end
      end
    end

    describe "bought and not bought filters" do
      context "memberships that have changed tier" do
        before do
          @membership_product = create(:membership_product_with_preset_tiered_pricing)
          @old_tier = @membership_product.default_tier
          @new_tier = @membership_product.tiers.find_by(name: "Second Tier")
          email = generate(:email)
          original_purchase = create(:membership_purchase, email:, link: @membership_product, variant_attributes: [@old_tier])
          subscription = original_purchase.subscription
          create(:purchase, email:, link: @membership_product, subscription:, variant_attributes: [@old_tier])
          @new_original_purchase = create(:purchase, email:, link: @membership_product, subscription:, variant_attributes: [@new_tier], is_original_subscription_purchase: true, purchase_state: "not_charged")
          original_purchase.update!(is_archived_original_subscription_purchase: true)
        end

        it "returns true if the membership used to have the 'not bought' variant and currently has the 'bought' variant" do
          post = create(:seller_installment, seller: @membership_product.user, bought_variants: [@new_tier.external_id], not_bought_variants: [@old_tier.external_id])
          expect(post.purchase_passes_filters(@new_original_purchase)).to eq true
        end

        it "returns false if the membership used to have the 'bought' variant and currently has the 'not bought' variant" do
          post = create(:seller_installment, seller: @membership_product.user, bought_variants: [@old_tier.external_id], not_bought_variants: [@new_tier.external_id])
          expect(post.purchase_passes_filters(@new_original_purchase)).to eq false
        end
      end
    end
  end

  describe "#seller_post_passes_filters" do
    before do
      @creator = create(:user)
    end

    context "for created filters" do
      context "when created_before filter is set" do
        before do
          @post = create(:seller_installment, seller: @creator, json_data: { created_before: 1.day.ago })
        end

        it "returns true for max_created_at older than the created_before date" do
          expect(@post.seller_post_passes_filters(max_created_at: 1.week.ago)).to eq(true)
        end

        it "returns false for max_created_at newer than the created_before date" do
          expect(@post.seller_post_passes_filters(max_created_at: Time.current)).to eq(false)
        end

        it "returns false when passed filters are missing" do
          expect(@post.seller_post_passes_filters).to eq(false)
        end
      end

      context "when created_after filter is set" do
        before do
          @post = create(:seller_installment, seller: @creator, json_data: { created_after: 1.day.ago })
        end

        it "returns true for min_created_at newer than the created_after date" do
          expect(@post.seller_post_passes_filters(min_created_at: Time.current)).to eq(true)
        end

        it "returns false for min_created_at older than the created_after date" do
          expect(@post.seller_post_passes_filters(min_created_at: 1.week.ago)).to eq(false)
        end

        it "returns false when passed filters are missing" do
          expect(@post.seller_post_passes_filters).to eq(false)
        end
      end

      context "when created_before and created_after filters are set" do
        before do
          @post = create(:seller_installment, seller: @creator, json_data: { created_after: 2.weeks.ago, created_before: 1.day.ago })
        end

        it "returns true when created timestamp filters are within the created dates" do
          expect(@post.seller_post_passes_filters(min_created_at: 1.week.ago, max_created_at: 2.days.ago)).to eq(true)
        end

        it "returns false for created timestamp filters are outside the created dates" do
          expect(@post.seller_post_passes_filters(min_created_at: 3.weeks.ago, max_created_at: 2.days.ago)).to eq(false)
          expect(@post.seller_post_passes_filters(min_created_at: 1.week.ago, max_created_at: Time.current)).to eq(false)
        end

        it "returns false when passed filters are missing" do
          expect(@post.seller_post_passes_filters).to eq(false)
        end
      end
    end

    context "for price filters" do
      context "when paid_more_than_cents filter is set" do
        before do
          @post = create(:seller_installment, seller: @creator, json_data: { paid_more_than_cents: 100 })
        end

        it "returns true for min_price_cents higher than the paid_more_than_cents" do
          expect(@post.seller_post_passes_filters(min_price_cents: 150)).to eq(true)
        end

        it "returns false for min_price_cents lower than the paid_more_than_cents" do
          expect(@post.seller_post_passes_filters(min_price_cents: 50)).to eq(false)
        end

        it "returns false when passed filters are missing" do
          expect(@post.seller_post_passes_filters).to eq(false)
        end
      end

      context "when paid_less_than_cents filter is set" do
        before do
          @post = create(:seller_installment, seller: @creator, json_data: { paid_less_than_cents: 100 })
        end

        it "returns true for max_price_cents lower than the paid_less_than_cents" do
          expect(@post.seller_post_passes_filters(max_price_cents: 50)).to eq(true)
        end

        it "returns false for max_price_cents higher than the paid_less_than_cents" do
          expect(@post.seller_post_passes_filters(max_price_cents: 150)).to eq(false)
        end

        it "returns false when passed filters are missing" do
          expect(@post.seller_post_passes_filters).to eq(false)
        end
      end

      context "when paid_more_than_cents and paid_less_than_cents filters are set" do
        before do
          @post = create(:seller_installment, seller: @creator, json_data: { paid_more_than_cents: 100, paid_less_than_cents: 500 })
        end

        it "returns true when price filters are within the post's price range" do
          expect(@post.seller_post_passes_filters(min_price_cents: 200, max_price_cents: 200)).to eq(true)
        end

        it "returns false when price filters are outside the post's price range" do
          expect(@post.seller_post_passes_filters(min_price_cents: 99, max_price_cents: 200)).to eq(false)
          expect(@post.seller_post_passes_filters(min_price_cents: 200, max_price_cents: 1000)).to eq(false)
          expect(@post.seller_post_passes_filters(min_price_cents: 50, max_price_cents: 1000)).to eq(false)
        end

        it "returns false when passed filters are missing" do
          expect(@post.seller_post_passes_filters).to eq(false)
        end
      end
    end

    context "when bought from country filter is set" do
      before do
        @post = create(:seller_installment, seller: @creator, json_data: { bought_from: "United States" })
      end

      it "returns true for country matching the selected bought_from country filter" do
        expect(@post.seller_post_passes_filters(country: "United States")).to eq(true)
      end

      it "returns true for ip_country matching the selected bought_from country filter" do
        expect(@post.seller_post_passes_filters(ip_country: "United States")).to eq(true)
      end

      it "returns false for country different than the selected bought_from country filter" do
        expect(@post.seller_post_passes_filters(country: "Canada")).to eq(false)
      end

      it "returns false for ip_country different than the selected bought_from country filter" do
        expect(@post.seller_post_passes_filters(country: "Canada")).to eq(false)
      end

      it "returns false when passed filters are missing" do
        expect(@post.seller_post_passes_filters).to eq(false)
      end
    end

    describe "bought products and variants filters" do
      describe "bought products only" do
        it "returns false when passed filters are missing" do
          post = create(:seller_installment, seller: @creator, json_data: { bought_products: ["a"] })
          expect(post.seller_post_passes_filters).to eq(false)
        end

        it "returns false when product permalinks don't match the bought_products filter" do
          post = create(:seller_installment, seller: @creator, json_data: { bought_products: %w[a b] })
          expect(post.seller_post_passes_filters(product_permalinks: %w[c d e])).to eq(false)
        end

        it "returns true when one product permalink matches the bought_products filter" do
          post = create(:seller_installment, seller: @creator, json_data: { bought_products: %w[a b] })
          expect(post.seller_post_passes_filters(product_permalinks: %w[b c d])).to eq(true)
        end
      end

      describe "bought variants only" do
        # The stored bought_variants must be real variant external ids: saving an
        # installment validates the seller's sending limit with an Elasticsearch
        # audience count (unconditional since the audience_count_from_elasticsearch
        # flag removal, gp#1208 / #6232), and made-up ids decrypt to nil, which
        # produces an invalid ES terms query. The external ids passed to
        # seller_post_passes_filters are only string-matched in memory, so
        # arbitrary values are still fine there.
        let(:variant_a) { create(:variant, variant_category: create(:variant_category, link: create(:product, user: @creator))) }
        let(:variant_b) { create(:variant, variant_category: create(:variant_category, link: create(:product, user: @creator))) }

        it "returns false when passed filters are missing" do
          post = create(:seller_installment, seller: @creator, json_data: { bought_variants: [variant_a.external_id] })
          expect(post.seller_post_passes_filters).to eq(false)
        end

        it "returns false when variant external ids don't match the bought_variants filter" do
          post = create(:seller_installment, seller: @creator, json_data: { bought_variants: [variant_a.external_id, variant_b.external_id] })
          expect(post.seller_post_passes_filters(variant_external_ids: %w[c d e])).to eq(false)
        end

        it "returns true when one variant external id matches the bought_variants filter" do
          post = create(:seller_installment, seller: @creator, json_data: { bought_variants: [variant_a.external_id, variant_b.external_id] })
          expect(post.seller_post_passes_filters(variant_external_ids: [variant_b.external_id, "c", "d"])).to eq(true)
        end
      end
    end

    describe "with preloaded caches" do
      before do
        @product = create(:product, user: @creator)
        @purchase = create(:purchase, link: @product, seller: @creator)
      end

      it "uses permalink_to_link_id cache to exclude buyers of not_bought_products" do
        post = create(:seller_installment, seller: @creator, json_data: { not_bought_products: [@product.unique_permalink] })
        permalink_to_link_id = { @product.unique_permalink => @product.id }

        expect(post.seller_post_passes_filters(
          email: @purchase.email,
          permalink_to_link_id:,
          seller_sales: @creator.sales
        )).to eq(false)
      end

      it "returns true via cache when buyer has not purchased the excluded product" do
        other_product = create(:product, user: @creator)
        post = create(:seller_installment, seller: @creator, json_data: { not_bought_products: [other_product.unique_permalink] })
        permalink_to_link_id = { other_product.unique_permalink => other_product.id }

        expect(post.seller_post_passes_filters(
          email: @purchase.email,
          permalink_to_link_id:,
          seller_sales: @creator.sales
        )).to eq(true)
      end

      it "uses seller_sales scope instead of seller association" do
        post = create(:seller_installment, seller: @creator, json_data: { not_bought_products: [@product.unique_permalink] })

        expect(post.seller_post_passes_filters(
          email: @purchase.email,
          seller_sales: @creator.sales
        )).to eq(false)
      end

      it "forwards caches through purchase_passes_filters" do
        post = create(:seller_installment, seller: @creator, json_data: { not_bought_products: [@product.unique_permalink] })
        permalink_to_link_id = { @product.unique_permalink => @product.id }

        expect(post.purchase_passes_filters(
          @purchase,
          permalink_to_link_id:,
          seller_sales: @creator.sales
        )).to eq(false)
      end

      it "does not reuse another seller's cached probe result for the same targeting signature and email" do
        other_seller = create(:user)
        post_a = create(:seller_installment, seller: @creator, json_data: { not_bought_products: [@product.unique_permalink] })
        post_b = create(:seller_installment, seller: other_seller, json_data: { not_bought_products: ["reused-permalink"] })
        shared_cache = {}

        # Buyer bought @product from @creator, so seller A's post excludes them.
        # This warms the shared cache with a `true` (matched) entry.
        expect(post_a.seller_post_passes_filters(
          email: @purchase.email,
          permalink_to_link_id: { @product.unique_permalink => @product.id },
          seller_sales: @creator.sales,
          seller_post_filter_cache: shared_cache
        )).to eq(false)

        # Seller B's post resolves to the same product id / variant / email
        # signature (e.g. a recycled permalink). The buyer has NOT bought
        # anything from seller B, so B's post must pass — the cache entry from
        # seller A must not be reused across sellers.
        expect(post_b.seller_post_passes_filters(
          email: @purchase.email,
          permalink_to_link_id: { "reused-permalink" => @product.id },
          seller_sales: other_seller.sales,
          seller_post_filter_cache: shared_cache
        )).to eq(true)
      end
    end

    describe "with a seller post probe batch" do
      before do
        @product = create(:product, user: @creator)
        @purchase = create(:free_purchase, link: @product, seller: @creator)
      end

      it "answers the probe from the batch without issuing the per-seller SQL probe" do
        post = create(:seller_installment, seller: @creator, json_data: { not_bought_products: [@product.unique_permalink] })
        batch = Purchase::SellerPostProbeBatch.new([@purchase])
        expect(batch).to receive(:matched?).with(hash_including(seller_id: @creator.id, email: @purchase.email)).and_call_original

        result = nil
        queries = []
        callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          result = post.seller_post_passes_filters(
            email: @purchase.email,
            permalink_to_link_id: { @product.unique_permalink => @product.id },
            seller_post_probe_batch: batch
          )
        end

        expect(result).to eq(false)
        # The batch prefetch queries purchases via `email IN (...)`; the
        # per-seller probe it replaces is an existence check with `LIMIT 1`
        # and a `seller_id` equality — none of those should run.
        expect(queries.grep(/SELECT\s+1.*purchases.*LIMIT 1/m)).to be_empty
      end

      it "falls back to the SQL probe when the batch does not cover the probe email" do
        other_buyer = create(:free_purchase, link: @product, seller: @creator)
        post = create(:seller_installment, seller: @creator, json_data: { not_bought_products: [@product.unique_permalink] })
        batch = Purchase::SellerPostProbeBatch.new([@purchase])

        expect(post.seller_post_passes_filters(
          email: other_buyer.email,
          permalink_to_link_id: { @product.unique_permalink => @product.id },
          seller_post_probe_batch: batch
        )).to eq(false)
      end

      it "falls back to the SQL probe when the batch covers the email but not the post's seller" do
        # The batch was built from another seller's purchases, so it never
        # prefetched @creator's rows. Answering from the (incomplete) batch
        # would wrongly report "hasn't bought" and show the post; the SQL
        # probe must run instead and hide it.
        other_seller = create(:user)
        other_purchase = create(:free_purchase, link: create(:product, user: other_seller), seller: other_seller, email: @purchase.email)
        post = create(:seller_installment, seller: @creator, json_data: { not_bought_products: [@product.unique_permalink] })
        batch = Purchase::SellerPostProbeBatch.new([other_purchase])
        expect(batch).not_to receive(:matched?)

        expect(post.seller_post_passes_filters(
          email: @purchase.email,
          permalink_to_link_id: { @product.unique_permalink => @product.id },
          seller_post_probe_batch: batch
        )).to eq(false)
      end
    end
  end

  describe "#affiliate_passes_filters" do
    context "for created filters" do
      before do
        @product = create(:product)
        @direct_affiliate = create(:direct_affiliate, seller: @product.user)
        @old_direct_affiliate = create(:direct_affiliate, seller: @product.user, created_at: 1.month.ago)
      end

      context "when created_before filter is set" do
        before do
          @post = create(:affiliate_installment, seller: @product.user, json_data: { created_before: 1.day.ago })
        end

        it "returns true for affiliates older than the created_before date" do
          expect(@post.affiliate_passes_filters(@old_direct_affiliate)).to eq(true)
        end

        it "returns false for affiliates newer than the created_before date" do
          expect(@post.affiliate_passes_filters(@direct_affiliate)).to eq(false)
        end
      end

      context "when created_after filter is set" do
        before do
          @post = create(:seller_installment, seller: @product.user, json_data: { created_after: 1.day.ago })
        end

        it "returns true for affiliates newer than the created_after date" do
          expect(@post.affiliate_passes_filters(@direct_affiliate)).to eq(true)
        end

        it "returns false for affiliates older than the created_after date" do
          expect(@post.affiliate_passes_filters(@old_direct_affiliate)).to eq(false)
        end
      end

      context "when created_before and created_after filters are set" do
        before do
          @direct_affiliate_2 = create(:direct_affiliate, seller: @product.user, created_at: 1.week.ago)
          @post = create(:affiliate_installment, seller: @product.user, json_data: { created_after: 2.weeks.ago, created_before: 1.day.ago })
        end

        it "returns true for affiliates within the created dates" do
          expect(@post.affiliate_passes_filters(@direct_affiliate_2)).to eq(true)
        end

        it "returns false for affiliates outside the created dates" do
          expect(@post.affiliate_passes_filters(@direct_affiliate)).to eq(false)
          expect(@post.affiliate_passes_filters(@old_direct_affiliate)).to eq(false)
        end
      end
    end
  end

  describe "#follower_passes_filters" do
    context "for created filters" do
      before do
        @product = create(:product)
        user = create(:user, email: "follower@gum.co")
        old_user = create(:user, email: "follower2@gum.co")
        @follower = create(:follower, user: @product.user, email: user.email)
        @old_follower = create(:follower, user: @product.user, email: old_user.email, created_at: 1.month.ago)
      end

      context "when created_before filter is set" do
        before do
          @post = create(:follower_installment, seller: @product.user, json_data: { created_before: 1.day.ago })
        end

        it "returns true for followers older than the created_before date" do
          expect(@post.follower_passes_filters(@old_follower)).to eq(true)
        end

        it "returns false for followers newer than the created_before date" do
          expect(@post.follower_passes_filters(@follower)).to eq(false)
        end
      end

      context "when created_after filter is set" do
        before do
          @post = create(:follower_installment, seller: @product.user, json_data: { created_after: 1.day.ago })
        end

        it "returns true for followers newer than the created_after date" do
          expect(@post.follower_passes_filters(@follower)).to eq(true)
        end

        it "returns false for followers older than the created_after date" do
          expect(@post.follower_passes_filters(@old_follower)).to eq(false)
        end
      end

      context "when created_before and created_after filters are set" do
        before do
          user = create(:user, email: "follower3@gum.co")
          @follower_2 = create(:follower, user: @product.user, email: user.email, created_at: 1.week.ago)
          @post = create(:follower_installment, seller: @product.user, json_data: { created_after: 2.weeks.ago, created_before: 1.day.ago })
        end

        it "returns true for followers within the created dates" do
          expect(@post.affiliate_passes_filters(@follower_2)).to eq(true)
        end

        it "returns false for followers outside the created dates" do
          expect(@post.affiliate_passes_filters(@follower)).to eq(false)
          expect(@post.affiliate_passes_filters(@old_follower)).to eq(false)
        end
      end
    end
  end

  describe "waitlisted products filter" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:follower) { create(:active_follower, user: seller) }

    it "keeps the filter only on follower emails" do
      follower_post = build(:follower_installment, seller:)
      audience_post = build(:audience_installment, seller:)

      [follower_post, audience_post].each { _1.add_and_validate_filters({ waitlisted_products: [product.unique_permalink] }, seller) }

      expect(follower_post.waitlisted_products).to eq([product.unique_permalink])
      expect(follower_post.json_filters[:waitlisted_products]).to eq([product.unique_permalink])
      expect(follower_post.audience_members_filter_params[:waitlisted_product_ids]).to eq([product.id])
      expect(audience_post.waitlisted_products).to be_blank
      expect(audience_post.audience_members_filter_params).not_to have_key(:waitlisted_product_ids)
    end

    it "matches nobody when no listed product resolves" do
      create(:waitlist_entry, follower:, product:)
      post = build(:follower_installment, seller:, json_data: { waitlisted_products: ["missing"] })

      expect(AudienceMember.filter(seller_id: seller.id, params: post.audience_members_filter_params, with_ids: true).to_a).to eq([])
    end

    it "passes a follower only when they joined the waitlist of a listed product" do
      post = create(:follower_installment, seller:, json_data: { waitlisted_products: [product.unique_permalink] })

      expect(post.follower_passes_filters(follower)).to eq(false)

      create(:waitlist_entry, follower:, product: create(:product, user: seller))
      expect(post.follower_passes_filters(follower)).to eq(false)

      create(:waitlist_entry, follower:, product:)
      expect(post.follower_passes_filters(Follower.find(follower.id))).to eq(true)
    end

    it "looks up the follower's waitlists once across posts" do
      create(:waitlist_entry, follower:, product:)
      posts = create_list(:follower_installment, 3, seller:, json_data: { waitlisted_products: [product.unique_permalink] })
      queries = []
      counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?("waitlist_entries") }

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        expect(posts.map { _1.follower_passes_filters(follower) }).to eq([true, true, true])
      end
      expect(queries.size).to eq(1)
    end
  end

  describe "#abandoned_cart_type?" do
    it "returns true if the installment type is abandoned_cart" do
      post = create(:installment, installment_type: Installment::ABANDONED_CART_TYPE)
      expect(post.abandoned_cart_type?).to be(true)
    end

    it "returns true if the workflow type is abandoned_cart" do
      workflow = create(:abandoned_cart_workflow)
      expect(workflow.abandoned_cart_type?).to be(true)
    end

    it "returns false if the installment type is not abandoned_cart" do
      post = create(:seller_installment)
      expect(post.abandoned_cart_type?).to be(false)
    end

    it "returns false if the workflow type is not abandoned_cart" do
      workflow = create(:workflow)
      expect(workflow.abandoned_cart_type?).to be(false)
    end
  end

  describe "not clicked filter" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }

    it "persists the referenced post so the composer can restore it" do
      post = build(:seller_installment, seller:)
      post.add_and_validate_filters({ not_clicked_post_id: "abc123" }, seller)

      expect(post.not_clicked_post_id).to eq("abc123")
      expect(post.json_filters[:not_clicked_post_id]).to eq("abc123")
    end

    it "excludes a clicker of the seller's own post, and matches nobody for another seller's post" do
      clicker = create(:free_purchase, link: product, seller:, email: "Clicker@Example.com")
      own_post = create(:seller_post, seller:, published_at: 1.day.ago)
      other_post = create(:seller_post, seller: create(:user), published_at: 1.day.ago)
      allow(EmailEngagementDynamoStore).to receive(:clicked_recipient_purchase_ids)
        .with(own_post.id).and_return([clicker.id])

      own = build(:seller_installment, seller:)
      own.add_and_validate_filters({ not_clicked_post_id: own_post.external_id }, seller)
      expect(own.audience_members_filter_params[:exclude_emails]).to eq(["clicker@example.com"])

      other = build(:seller_installment, seller:)
      other.add_and_validate_filters({ not_clicked_post_id: other_post.external_id }, seller)
      expect(other.audience_members_filter_params).not_to have_key(:exclude_emails)
      expect(other.audience_members_filter_params[:include_emails]).to eq([""])
    end

    it "excludes nobody when nobody clicked the seller's own post" do
      own_post = create(:seller_post, seller:, published_at: 1.day.ago)
      allow(EmailEngagementDynamoStore).to receive(:clicked_recipient_purchase_ids).with(own_post.id).and_return([])

      installment = build(:seller_installment, seller:, not_clicked_post_id: own_post.external_id)
      expect(installment.audience_members_filter_params.keys).not_to include(:include_emails, :exclude_emails)
    end
  end

  describe "opened filter" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }

    it "limits the audience to openers of the seller's own post, and to nobody when none resolve" do
      opener = create(:free_purchase, link: product, seller:, email: "Opener@Example.com")
      own_post = create(:seller_post, seller:, published_at: 1.day.ago)
      allow(EmailEngagementDynamoStore).to receive(:opened_recipient_purchase_ids).with(own_post.id).and_return([opener.id])

      own = build(:seller_installment, seller:)
      own.add_and_validate_filters({ opened_post_id: own_post.external_id }, seller)
      expect(own.json_filters[:opened_post_id]).to eq(own_post.external_id)
      expect(own.audience_members_filter_params[:include_emails]).to eq(["opener@example.com"])

      allow(EmailEngagementDynamoStore).to receive(:opened_recipient_purchase_ids).with(own_post.id).and_return([])
      none_opened = build(:seller_installment, seller:)
      none_opened.add_and_validate_filters({ opened_post_id: own_post.external_id }, seller)
      expect(none_opened.audience_members_filter_params[:include_emails]).to eq([""])
    end

    it "matches nobody for another seller's post" do
      other_post = create(:seller_post, seller: create(:user), published_at: 1.day.ago)
      installment = build(:seller_installment, seller:)
      installment.add_and_validate_filters({ opened_post_id: other_post.external_id }, seller)

      expect(installment.audience_members_filter_params[:include_emails]).to eq([""])
    end

    it "reads the post's opens once per installment" do
      own_post = create(:seller_post, seller:, published_at: 1.day.ago)
      installment = build(:seller_installment, seller:, opened_post_id: own_post.external_id)
      expect(EmailEngagementDynamoStore).to receive(:opened_recipient_purchase_ids).with(own_post.id).once.and_return([])

      2.times { installment.audience_members_filter_params }
    end
  end

  describe "#displayed_audience_members_count" do
    let(:seller) { create(:user) }
    let(:installment) { build(:seller_installment, seller:) }

    # `count` members with the behavior filter applied, `left_out` more without it.
    def stub_counts(count, left_out: 0)
      allow(AudienceMember).to receive(:filter_count) do |params:, **|
        params.key?(:include_emails) || params.key?(:exclude_emails) ? count : count + left_out
      end
    end

    context "with a has-opened filter" do
      before { installment.opened_post_id = "abc" }

      it "withholds a count below the floor" do
        stub_counts(Installment::MINIMUM_BEHAVIOR_SEGMENT_SIZE - 1)

        expect(installment.displayed_audience_members_count).to be_nil
      end

      it "shows a count at the floor" do
        stub_counts(Installment::MINIMUM_BEHAVIOR_SEGMENT_SIZE)

        expect(installment.displayed_audience_members_count).to eq(Installment::MINIMUM_BEHAVIOR_SEGMENT_SIZE)
      end
    end

    it "withholds a has-not-clicked count while the part it leaves out is below the floor" do
      installment.not_clicked_post_id = "abc"
      allow(installment).to receive(:clicked_recipient_emails).with("abc").and_return(["clicker@example.com"])

      stub_counts(48, left_out: Installment::MINIMUM_BEHAVIOR_SEGMENT_SIZE - 1)
      expect(installment.displayed_audience_members_count).to be_nil

      stub_counts(48, left_out: Installment::MINIMUM_BEHAVIOR_SEGMENT_SIZE)
      expect(installment.displayed_audience_members_count).to eq(48)
    end

    it "withholds a count with both filters while either one alone leaves out fewer than the floor" do
      installment.opened_post_id = "abc"
      installment.not_clicked_post_id = "def"
      allow(installment).to receive(:opened_recipient_emails).with("abc").and_return(["opener@example.com"])
      allow(installment).to receive(:clicked_recipient_emails).with("def").and_return(["clicker@example.com"])
      # 40 match both, 41 with only "Has opened" applied, 60 with only "Has not clicked", 80 with neither.
      allow(AudienceMember).to receive(:filter_count) do |params:, **|
        { [true, true] => 40, [true, false] => 41, [false, true] => 60, [false, false] => 80 }
          .fetch([params.key?(:include_emails), params.key?(:exclude_emails)])
      end

      expect(installment.displayed_audience_members_count).to be_nil
    end

    it "shows small counts without a behavior filter" do
      stub_counts(1)

      expect(installment.displayed_audience_members_count).to eq(1)
    end
  end

  describe "#delivery_counts_withheld?" do
    let(:seller) { create(:user) }
    let(:installment) { build(:seller_installment, seller:, not_clicked_post_id: "abc", customer_count: 49) }

    before { allow(installment).to receive(:clicked_recipient_emails).with("abc").and_return(["clicker@example.com"]) }

    it "reads the decision stored at send time without resolving the filter" do
      expect(AudienceMember).not_to receive(:filter_count)

      installment.delivery_counts_withheld = false
      expect(installment.delivery_counts_withheld?).to be(false)

      installment.delivery_counts_withheld = true
      expect(installment.delivery_counts_withheld?).to be(true)
    end

    it "withholds a sent count of a post sent before the decision was stored that leaves out fewer than the floor of today's audience" do
      allow(AudienceMember).to receive(:filter_count) { |params:, **| params.key?(:exclude_emails) ? 49 : 50 }
      expect(installment.delivery_counts_withheld?).to be(true)

      allow(AudienceMember).to receive(:filter_count) { |params:, **| params.key?(:exclude_emails) ? 49 : 54 }
      expect(installment.delivery_counts_withheld?).to be(false)
    end

    it "shows the sent count of an email without a behavior filter" do
      installment.not_clicked_post_id = nil

      expect(installment.delivery_counts_withheld?(1)).to be(false)
    end

    it "shows the counts of a filtered post that was not emailed without resolving the filter" do
      installment.send_emails = false
      expect(AudienceMember).not_to receive(:filter_count)

      expect(installment.delivery_counts_withheld?(1)).to be(false)
    end
  end
end
