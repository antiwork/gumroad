# frozen_string_literal: true

require "spec_helper"

describe "Purchase inventory counter cache" do
  let(:product) { create(:product) }
  let(:variant_category) { create(:variant_category, link: product) }
  let(:variant) { create(:variant, variant_category:) }

  describe "#counts_towards_inventory?" do
    it "returns true for a successful non-subscription purchase" do
      purchase = create(:purchase, link: product, purchase_state: "successful")
      expect(purchase.counts_towards_inventory?).to eq(true)
    end

    it "returns false for a failed purchase" do
      purchase = build(:purchase, link: product, purchase_state: "failed")
      expect(purchase.counts_towards_inventory?).to eq(false)
    end

    it "returns false for additional contribution" do
      purchase = create(:purchase, link: product, purchase_state: "successful", is_additional_contribution: true)
      expect(purchase.counts_towards_inventory?).to eq(false)
    end

    it "returns false for archived original subscription purchase" do
      purchase = create(:purchase, link: product, purchase_state: "successful", is_archived_original_subscription_purchase: true)
      expect(purchase.counts_towards_inventory?).to eq(false)
    end
  end

  describe "cache maintenance" do
    it "increments variant and link cache when a counting purchase is created" do
      expect do
        create(:purchase, link: product, variant_attributes: [variant], purchase_state: "successful", quantity: 2)
      end.to change { variant.reload.sales_count_for_inventory_cache }.by(2)
        .and change { product.reload.sales_count_for_inventory_cache }.by(2)
    end

    it "decrements cache when a counting purchase transitions to a non-counting state" do
      purchase = create(:purchase, link: product, variant_attributes: [variant], purchase_state: "successful", quantity: 3)
      expect do
        purchase.update!(purchase_state: "failed")
      end.to change { variant.reload.sales_count_for_inventory_cache }.by(-3)
        .and change { product.reload.sales_count_for_inventory_cache }.by(-3)
    end

    it "decrements cache when a counting purchase is destroyed" do
      purchase = create(:purchase, link: product, variant_attributes: [variant], purchase_state: "successful", quantity: 1)
      expect do
        purchase.destroy!
      end.to change { variant.reload.sales_count_for_inventory_cache }.by(-1)
        .and change { product.reload.sales_count_for_inventory_cache }.by(-1)
    end

    it "does not double-count when unrelated attributes change" do
      purchase = create(:purchase, link: product, variant_attributes: [variant], purchase_state: "successful", quantity: 1)
      variant.reload
      product.reload
      expect do
        purchase.update!(email: "new@example.com")
      end.to not_change { variant.reload.sales_count_for_inventory_cache }
        .and not_change { product.reload.sales_count_for_inventory_cache }
    end
  end

  describe "subscription deactivation" do
    let(:membership) { create(:membership_product) }
    let(:membership_variant) { membership.variant_categories_alive.first.variants.first }

    it "subtracts counted quantity from variant and product when subscription deactivates, restores on reactivation" do
      subscription = create(:subscription, link: membership)
      create(:purchase,
             link: membership,
             subscription: subscription,
             variant_attributes: [membership_variant],
             is_original_subscription_purchase: true,
             purchase_state: "successful",
             quantity: 1)

      expect(membership_variant.reload.sales_count_for_inventory_cache).to eq(1)
      expect(membership.reload.sales_count_for_inventory_cache).to eq(1)

      expect { subscription.update!(deactivated_at: Time.current) }
        .to change { membership_variant.reload.sales_count_for_inventory_cache }.by(-1)
        .and change { membership.reload.sales_count_for_inventory_cache }.by(-1)

      expect { subscription.update!(deactivated_at: nil) }
        .to change { membership_variant.reload.sales_count_for_inventory_cache }.by(1)
        .and change { membership.reload.sales_count_for_inventory_cache }.by(1)
    end
  end

  describe "refund flow" do
    it "keeps cached value unchanged when a successful purchase is partially refunded" do
      purchase = create(:purchase, link: product, variant_attributes: [variant], purchase_state: "successful", quantity: 1)
      variant.reload
      product.reload
      expect do
        purchase.update!(stripe_partially_refunded: true)
      end.to not_change { variant.reload.sales_count_for_inventory_cache }
        .and not_change { product.reload.sales_count_for_inventory_cache }
    end
  end

  describe "per purchase type" do
    describe "gift purchases" do
      let(:gift_product) { create(:product) }

      it "counts the gift sender purchase but not the gift receiver purchase" do
        gift = create(:gift, gifter_email: "sender@example.com", giftee_email: "receiver@example.com", link: gift_product)
        sender = create(:purchase, link: gift_product, is_gift_sender_purchase: true, gift_given: gift, purchase_state: "successful", quantity: 1)
        receiver = create(:purchase, link: gift_product, is_gift_receiver_purchase: true, gift_received: gift, purchase_state: "gift_receiver_purchase_successful", quantity: 1)

        expect(sender.counts_towards_inventory?).to eq(true)
        expect(receiver.counts_towards_inventory?).to eq(false)
      end

      it "counts a gift receiver purchase for a subscription" do
        membership = create(:membership_product)
        sub = create(:subscription, link: membership)
        receiver = create(:membership_purchase, subscription: sub, is_gift_receiver_purchase: true, purchase_state: "successful")

        expect(receiver.counts_towards_inventory?).to eq(true)
      end
    end

    describe "preorder authorization purchases" do
      it "counts a preorder authorization as part of inventory" do
        preorder_product = create(:product, is_in_preorder_state: true)
        purchase = create(:preorder_authorization_purchase, link: preorder_product, quantity: 1)
        expect(purchase.counts_towards_inventory?).to eq(true)
        expect(preorder_product.reload.sales_count_for_inventory_cache).to eq(1)
      end
    end

    describe "membership (subscription) purchases" do
      let(:membership) { create(:membership_product) }

      it "counts the original subscription purchase" do
        purchase = create(:membership_purchase, link: membership, quantity: 1)
        expect(purchase.counts_towards_inventory?).to eq(true)
      end

      it "does not count a recurring (non-original) subscription charge" do
        sub = create(:subscription, link: membership)
        create(:membership_purchase, link: membership, subscription: sub)
        recurring = create(:recurring_membership_purchase, link: membership, subscription: sub, purchase_state: "successful")
        expect(recurring.counts_towards_inventory?).to eq(false)
      end
    end

    describe "bundle purchases" do
      it "counts both bundle parent and bundle product purchases" do
        bundle = create(:product, :bundle)
        bundle_purchase = create(:purchase, link: bundle, is_bundle_purchase: true, purchase_state: "successful", quantity: 1)
        bundle_product_purchase = create(:purchase, link: bundle.bundle_products.first.product, is_bundle_product_purchase: true, purchase_state: "successful", quantity: 1)

        expect(bundle_purchase.counts_towards_inventory?).to eq(true)
        expect(bundle_product_purchase.counts_towards_inventory?).to eq(true)
      end
    end

    describe "combined charge purchases" do
      it "counts combined charge child purchases" do
        purchase = create(:purchase, link: product, is_part_of_combined_charge: true, purchase_state: "successful", quantity: 1)
        expect(purchase.counts_towards_inventory?).to eq(true)
      end
    end

    describe "installment plan purchases" do
      it "counts the original installment plan purchase" do
        purchase = create(:installment_plan_purchase, purchase_state: "successful", quantity: 1)
        expect(purchase.counts_towards_inventory?).to eq(true)
      end

      it "does not count a recurring installment payment" do
        installment_product = create(:product, :with_installment_plan)
        sub = create(:subscription, link: installment_product, is_installment_plan: true)
        create(:installment_plan_purchase, subscription: sub, link: installment_product, purchase_state: "successful")
        recurring = create(:recurring_installment_plan_purchase, subscription: sub, link: installment_product, purchase_state: "successful")
        expect(recurring.counts_towards_inventory?).to eq(false)
      end
    end
  end

  describe "multi-save in a single outer transaction" do
    it "increments cache by quantity when purchase_state goes failed -> in_progress -> successful in one transaction" do
      purchase = create(:purchase, link: product, variant_attributes: [variant], purchase_state: "failed", quantity: 2)
      variant.reload
      product.reload

      ActiveRecord::Base.transaction do
        purchase.update!(purchase_state: "in_progress")
        purchase.update!(purchase_state: "successful")
      end

      expect(variant.reload.sales_count_for_inventory_cache).to eq(2)
      expect(product.reload.sales_count_for_inventory_cache).to eq(2)
    end

    it "leaves cache unchanged when purchase_state goes failed -> in_progress -> failed in one transaction" do
      purchase = create(:purchase, link: product, variant_attributes: [variant], purchase_state: "failed", quantity: 2)
      variant.reload
      product.reload

      ActiveRecord::Base.transaction do
        purchase.update!(purchase_state: "in_progress")
        purchase.update!(purchase_state: "failed")
      end

      expect(variant.reload.sales_count_for_inventory_cache).to eq(0)
      expect(product.reload.sales_count_for_inventory_cache).to eq(0)
    end

    it "leaves cache unchanged when archive flag flips on then off on the same purchase in one transaction" do
      membership = create(:membership_product)
      v = membership.variant_categories_alive.first.variants.first
      subscription = create(:subscription, link: membership)
      purchase = create(:purchase, link: membership, subscription: subscription,
                                   variant_attributes: [v], is_original_subscription_purchase: true,
                                   purchase_state: "successful", quantity: 1)
      v.reload
      membership.reload

      ActiveRecord::Base.transaction do
        purchase.update!(is_archived_original_subscription_purchase: true)
        purchase.update!(is_archived_original_subscription_purchase: false)
      end

      expect(v.reload.sales_count_for_inventory_cache).to eq(1)
      expect(membership.reload.sales_count_for_inventory_cache).to eq(1)
    end

    it "does not drift when an original purchase is archived and the subscription is reactivated in the same transaction" do
      membership = create(:membership_product)
      v = membership.variant_categories_alive.first.variants.first
      subscription = create(:subscription, link: membership, deactivated_at: Time.current)
      purchase = create(:purchase, link: membership, subscription: subscription,
                                   variant_attributes: [v], is_original_subscription_purchase: true,
                                   purchase_state: "successful", quantity: 1)
      v.reload
      membership.reload
      expect(v.sales_count_for_inventory_cache).to eq(0)
      expect(membership.sales_count_for_inventory_cache).to eq(0)

      ActiveRecord::Base.transaction do
        purchase.update!(is_archived_original_subscription_purchase: true)
        subscription.update!(deactivated_at: nil)
      end

      expect(v.reload.sales_count_for_inventory_cache).to eq(0)
      expect(membership.reload.sales_count_for_inventory_cache).to eq(0)
    end
  end

  describe "reader gating on Feature flag" do
    let(:purchase) { create(:purchase, link: product, variant_attributes: [variant], purchase_state: "successful", quantity: 4) }

    before { purchase }

    it "returns the SUM when flag is off" do
      Feature.deactivate(:inventory_counter_cache)
      expect(variant.reload.sales_count_for_inventory).to eq(4)
      expect(product.reload.sales_count_for_inventory).to eq(4)
    end

    it "returns the cached column when flag is on" do
      Feature.activate(:inventory_counter_cache)
      variant.update_columns(sales_count_for_inventory_cache: 99)
      product.update_columns(sales_count_for_inventory_cache: 99)
      expect(variant.reload.sales_count_for_inventory).to eq(99)
      expect(product.reload.sales_count_for_inventory).to eq(99)
    ensure
      Feature.deactivate(:inventory_counter_cache)
    end
  end
end
