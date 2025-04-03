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
        it "returns false when passed filters are missing" do
          post = create(:seller_installment, seller: @creator, json_data: { bought_variants: ["a"] })
          expect(post.seller_post_passes_filters).to eq(false)
        end

        it "returns false when product permalinks don't match the bought_products filter" do
          post = create(:seller_installment, seller: @creator, json_data: { bought_variants: %w[a b] })
          expect(post.seller_post_passes_filters(variant_external_ids: %w[c d e])).to eq(false)
        end

        it "returns true when one product permalink matches the bought_products filter" do
          post = create(:seller_installment, seller: @creator, json_data: { bought_variants: %w[a b] })
          expect(post.seller_post_passes_filters(variant_external_ids: %w[b c d])).to eq(true)
        end
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
end
