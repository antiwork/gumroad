# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillInventoryCounterCache do
  describe ".process" do
    let(:product) { create(:product) }
    let(:variant_category) { create(:variant_category, link: product) }
    let(:variant) { create(:variant, variant_category:) }

    def create_historical_purchase(**attrs)
      Purchase.skip_inventory_counter_callbacks do
        create(:purchase, link: product, purchase_state: "successful", quantity: 1, **attrs)
      end
    end

    def set_caches(link_value:, variant_value: nil)
      Link.where(id: product.id).update_all(sales_count_for_inventory_cache: link_value)
      BaseVariant.where(id: variant.id).update_all(sales_count_for_inventory_cache: variant_value) unless variant_value.nil?
    end

    it "sums quantities of qualifying purchases into both link and variant caches" do
      create_historical_purchase(variant_attributes: [variant], quantity: 3)
      create_historical_purchase(variant_attributes: [variant], quantity: 2)

      described_class.process

      expect(variant.reload.sales_count_for_inventory_cache).to eq(5)
      expect(product.reload.sales_count_for_inventory_cache).to eq(5)
    end

    it "writes 0 when there are no qualifying purchases, overwriting any stale value" do
      variant
      set_caches(link_value: 999, variant_value: 999)

      described_class.process

      expect(variant.reload.sales_count_for_inventory_cache).to eq(0)
      expect(product.reload.sales_count_for_inventory_cache).to eq(0)
    end

    it "overwrites stale cache values with the correct sum" do
      create_historical_purchase(variant_attributes: [variant], quantity: 4)
      set_caches(link_value: 999, variant_value: 999)

      described_class.process

      expect(variant.reload.sales_count_for_inventory_cache).to eq(4)
      expect(product.reload.sales_count_for_inventory_cache).to eq(4)
    end

    it "is idempotent across repeated runs" do
      create_historical_purchase(variant_attributes: [variant], quantity: 7)

      described_class.process
      first = variant.reload.sales_count_for_inventory_cache

      described_class.process

      expect(variant.reload.sales_count_for_inventory_cache).to eq(first)
      expect(first).to eq(7)
    end

    describe "purchase state filtering" do
      it "excludes purchases not in COUNTS_TOWARDS_INVENTORY_STATES" do
        create_historical_purchase(variant_attributes: [variant], purchase_state: "successful", quantity: 1)
        create_historical_purchase(variant_attributes: [variant], purchase_state: "failed", quantity: 99)

        described_class.process

        expect(variant.reload.sales_count_for_inventory_cache).to eq(1)
        expect(product.reload.sales_count_for_inventory_cache).to eq(1)
      end

      it "includes preorder_authorization_successful, in_progress, and not_charged states" do
        create_historical_purchase(variant_attributes: [variant], purchase_state: "preorder_authorization_successful", quantity: 1)
        create_historical_purchase(variant_attributes: [variant], purchase_state: "in_progress", quantity: 1)
        create_historical_purchase(variant_attributes: [variant], purchase_state: "not_charged", quantity: 1)

        described_class.process

        expect(variant.reload.sales_count_for_inventory_cache).to eq(3)
        expect(product.reload.sales_count_for_inventory_cache).to eq(3)
      end
    end

    describe "flag-based filtering" do
      it "excludes additional contributions" do
        create_historical_purchase(variant_attributes: [variant], quantity: 1)
        create_historical_purchase(variant_attributes: [variant], is_additional_contribution: true, quantity: 99)

        described_class.process

        expect(variant.reload.sales_count_for_inventory_cache).to eq(1)
        expect(product.reload.sales_count_for_inventory_cache).to eq(1)
      end

      it "excludes archived original subscription purchases" do
        create_historical_purchase(variant_attributes: [variant], quantity: 1)
        create_historical_purchase(variant_attributes: [variant], is_archived_original_subscription_purchase: true, quantity: 99)

        described_class.process

        expect(variant.reload.sales_count_for_inventory_cache).to eq(1)
        expect(product.reload.sales_count_for_inventory_cache).to eq(1)
      end
    end

    describe "subscription handling" do
      let(:membership) { create(:membership_product) }
      let(:membership_variant) { membership.variant_categories_alive.first.variants.first }

      def reset_membership_caches
        Link.where(id: membership.id).update_all(sales_count_for_inventory_cache: 0)
        BaseVariant.where(id: membership_variant.id).update_all(sales_count_for_inventory_cache: 0)
      end

      def create_membership_purchase(subscription:, **attrs)
        Purchase.skip_inventory_counter_callbacks do
          create(:purchase,
                 link: membership,
                 subscription: subscription,
                 variant_attributes: [membership_variant],
                 purchase_state: "successful",
                 quantity: 1, **attrs)
        end
      end

      it "counts the original subscription purchase" do
        sub = create(:subscription, link: membership)
        create_membership_purchase(subscription: sub, is_original_subscription_purchase: true)
        reset_membership_caches

        described_class.process

        expect(membership_variant.reload.sales_count_for_inventory_cache).to eq(1)
        expect(membership.reload.sales_count_for_inventory_cache).to eq(1)
      end

      it "counts a gift receiver purchase on a subscription" do
        sub = create(:subscription, link: membership)
        create_membership_purchase(subscription: sub, is_gift_receiver_purchase: true)
        reset_membership_caches

        described_class.process

        expect(membership_variant.reload.sales_count_for_inventory_cache).to eq(1)
        expect(membership.reload.sales_count_for_inventory_cache).to eq(1)
      end

      it "does not count recurring (non-original, non-gift) subscription charges" do
        sub = create(:subscription, link: membership)
        create_membership_purchase(subscription: sub, is_original_subscription_purchase: true, quantity: 1)
        create_membership_purchase(subscription: sub, quantity: 99)
        reset_membership_caches

        described_class.process

        expect(membership_variant.reload.sales_count_for_inventory_cache).to eq(1)
        expect(membership.reload.sales_count_for_inventory_cache).to eq(1)
      end

      it "does not count subscription purchases when the subscription is deactivated" do
        sub = create(:subscription, link: membership, deactivated_at: 1.day.ago)
        create_membership_purchase(subscription: sub, is_original_subscription_purchase: true, quantity: 1)
        Link.where(id: membership.id).update_all(sales_count_for_inventory_cache: 5)
        BaseVariant.where(id: membership_variant.id).update_all(sales_count_for_inventory_cache: 5)

        described_class.process

        expect(membership_variant.reload.sales_count_for_inventory_cache).to eq(0)
        expect(membership.reload.sales_count_for_inventory_cache).to eq(0)
      end
    end

    describe "range scoping" do
      let!(:product_a) { create(:product) }
      let!(:product_b) { create(:product) }
      let!(:product_c) { create(:product) }

      def create_purchase_for(target_product)
        Purchase.skip_inventory_counter_callbacks do
          create(:purchase, link: target_product, purchase_state: "successful", quantity: 1)
        end
      end

      def reset_link_caches
        Link.where(id: [product_a.id, product_b.id, product_c.id]).update_all(sales_count_for_inventory_cache: 0)
      end

      it "respects start_link_id, leaving earlier links untouched" do
        create_purchase_for(product_a)
        create_purchase_for(product_b)
        create_purchase_for(product_c)
        Link.where(id: product_a.id).update_all(sales_count_for_inventory_cache: 999)
        Link.where(id: [product_b.id, product_c.id]).update_all(sales_count_for_inventory_cache: 0)

        described_class.process(start_link_id: product_b.id)

        expect(product_a.reload.sales_count_for_inventory_cache).to eq(999)
        expect(product_b.reload.sales_count_for_inventory_cache).to eq(1)
        expect(product_c.reload.sales_count_for_inventory_cache).to eq(1)
      end

      it "respects end_link_id, leaving later links untouched" do
        create_purchase_for(product_a)
        create_purchase_for(product_b)
        create_purchase_for(product_c)
        Link.where(id: product_c.id).update_all(sales_count_for_inventory_cache: 999)
        Link.where(id: [product_a.id, product_b.id]).update_all(sales_count_for_inventory_cache: 0)

        described_class.process(end_link_id: product_b.id)

        expect(product_a.reload.sales_count_for_inventory_cache).to eq(1)
        expect(product_b.reload.sales_count_for_inventory_cache).to eq(1)
        expect(product_c.reload.sales_count_for_inventory_cache).to eq(999)
      end

      it "respects start_base_variant_id and end_base_variant_id" do
        cat_a = create(:variant_category, link: product_a)
        cat_b = create(:variant_category, link: product_b)
        cat_c = create(:variant_category, link: product_c)
        var_a = create(:variant, variant_category: cat_a)
        var_b = create(:variant, variant_category: cat_b)
        var_c = create(:variant, variant_category: cat_c)

        Purchase.skip_inventory_counter_callbacks do
          create(:purchase, link: product_a, variant_attributes: [var_a], purchase_state: "successful", quantity: 1)
          create(:purchase, link: product_b, variant_attributes: [var_b], purchase_state: "successful", quantity: 1)
          create(:purchase, link: product_c, variant_attributes: [var_c], purchase_state: "successful", quantity: 1)
        end
        BaseVariant.where(id: var_a.id).update_all(sales_count_for_inventory_cache: 999)
        BaseVariant.where(id: var_c.id).update_all(sales_count_for_inventory_cache: 999)

        described_class.process(
          start_base_variant_id: var_b.id,
          end_base_variant_id: var_b.id,
          start_link_id: 2_000_000_000,
        )

        expect(var_a.reload.sales_count_for_inventory_cache).to eq(999)
        expect(var_b.reload.sales_count_for_inventory_cache).to eq(1)
        expect(var_c.reload.sales_count_for_inventory_cache).to eq(999)
      end

      it "supports running disjoint ranges in parallel without overlap" do
        create_purchase_for(product_a)
        create_purchase_for(product_b)
        create_purchase_for(product_c)
        reset_link_caches

        described_class.process(start_link_id: product_a.id, end_link_id: product_a.id)
        described_class.process(start_link_id: product_b.id, end_link_id: product_b.id)
        described_class.process(start_link_id: product_c.id, end_link_id: product_c.id)

        expect(product_a.reload.sales_count_for_inventory_cache).to eq(1)
        expect(product_b.reload.sales_count_for_inventory_cache).to eq(1)
        expect(product_c.reload.sales_count_for_inventory_cache).to eq(1)
      end
    end

    describe "aggregation across multiple purchases" do
      it "groups by base_variant_id correctly when multiple variants share an id range" do
        other_variant = create(:variant, variant_category:)
        Purchase.skip_inventory_counter_callbacks do
          create(:purchase, link: product, variant_attributes: [variant], purchase_state: "successful", quantity: 2)
          create(:purchase, link: product, variant_attributes: [variant], purchase_state: "successful", quantity: 3)
          create(:purchase, link: product, variant_attributes: [other_variant], purchase_state: "successful", quantity: 7)
        end

        described_class.process

        expect(variant.reload.sales_count_for_inventory_cache).to eq(5)
        expect(other_variant.reload.sales_count_for_inventory_cache).to eq(7)
        expect(product.reload.sales_count_for_inventory_cache).to eq(12)
      end
    end

    describe "batch_size parameter" do
      it "produces the same result with a small batch size as a large one" do
        create_historical_purchase(variant_attributes: [variant], quantity: 4)

        described_class.process(batch_size: 1)
        small_batch_value = variant.reload.sales_count_for_inventory_cache

        BaseVariant.where(id: variant.id).update_all(sales_count_for_inventory_cache: 0)
        Link.where(id: product.id).update_all(sales_count_for_inventory_cache: 0)
        described_class.process(batch_size: 10_000)

        expect(small_batch_value).to eq(4)
        expect(variant.reload.sales_count_for_inventory_cache).to eq(4)
        expect(product.reload.sales_count_for_inventory_cache).to eq(4)
      end
    end
  end
end
