# frozen_string_literal: true

require "spec_helper"

describe Subscription::Restartable, :sidekiq_inline do
  let(:seller) { create(:user) }
  let(:product) { create(:membership_product, user: seller) }
  let(:buyer) { create(:user) }

  # Helper to create a subscription with a proper original purchase
  def create_subscription_with_purchase(product:, purchaser:, **subscription_attrs)
    subscription = create(:subscription, link: product, user: purchaser)
    # Create purchase directly to avoid card charging issues
    create(:purchase,
           link: product,
           purchaser: purchaser,
           email: purchaser.email,
           subscription: subscription,
           is_original_subscription_purchase: true,
           price_cents: product.price_cents,
           variant_attributes: product.tiers.to_a
    )
    subscription.update!(subscription_attrs) if subscription_attrs.present?
    subscription
  end

  describe ".restartable_for_product_and_buyer" do
    context "when product is not a membership" do
      let(:regular_product) { create(:product, user: seller) }

      it "returns nil" do
        expect(Subscription.restartable_for_product_and_buyer(product: regular_product, buyer: buyer)).to be_nil
      end
    end

    context "when user has a cancelled subscription" do
      let!(:subscription) do
        create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
      end

      it "returns the subscription" do
        result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to eq(subscription)
      end
    end

    context "when user has a failed subscription" do
      let!(:subscription) do
        create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          failed_at: 1.day.ago,
          deactivated_at: 1.day.ago
        )
      end

      it "returns the subscription" do
        result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to eq(subscription)
      end
    end

    context "when subscription is cancelled by seller" do
      let!(:subscription) do
        create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: false,
          cancelled_by_admin: true,
          deactivated_at: 1.day.ago
        )
      end

      it "returns nil (not restartable)" do
        result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to be_nil
      end
    end

    context "when subscription has ended" do
      let!(:subscription) do
        create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          ended_at: 1.day.ago,
          deactivated_at: 1.day.ago
        )
      end

      it "returns nil (not restartable)" do
        result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to be_nil
      end
    end

    context "when subscription is active" do
      let!(:subscription) do
        create_subscription_with_purchase(product: product, purchaser: buyer)
      end

      it "returns nil (already active, not restartable)" do
        result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to be_nil
      end
    end

    context "when user has a deactivated test subscription" do
      let!(:subscription) do
        create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          is_test_subscription: true,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
      end

      it "returns nil (test subscriptions are excluded)" do
        result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to be_nil
      end
    end

    context "when user has no subscription" do
      it "returns nil" do
        result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to be_nil
      end
    end

    context "when the product has been banned" do
      let!(:subscription) do
        create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
      end

      before { product.update!(banned_at: 1.day.ago) }

      it "returns nil (a banned product cannot be restarted)" do
        result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to be_nil
      end
    end

    context "when the product has purchases disabled" do
      let!(:subscription) do
        create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
      end

      before { product.update!(purchase_disabled_at: 1.day.ago) }

      it "returns nil (purchases are disabled)" do
        result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to be_nil
      end
    end

    context "with multiple subscriptions" do
      let!(:older_subscription) do
        sub = create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          cancelled_at: 2.months.ago,
          cancelled_by_buyer: true,
          deactivated_at: 2.months.ago
        )
        sub.update_column(:created_at, 2.months.ago)
        sub
      end

      let!(:newer_subscription) do
        sub = create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
        sub.update_column(:created_at, 1.month.ago)
        sub
      end

      it "returns the most recently created subscription" do
        result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to eq(newer_subscription)
      end
    end
  end

  describe ".restartable_for_product_and_email" do
    context "when user has a cancelled subscription" do
      let!(:subscription) do
        create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
      end

      it "returns the subscription when matching by email" do
        result = Subscription.restartable_for_product_and_email(product: product, email: buyer.email)
        expect(result).to eq(subscription)
      end

      it "handles email case insensitivity" do
        result = Subscription.restartable_for_product_and_email(product: product, email: buyer.email.upcase)
        expect(result).to eq(subscription)
      end
    end

    context "when user has a deactivated test subscription" do
      let!(:subscription) do
        create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          is_test_subscription: true,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
      end

      it "returns nil (test subscriptions are excluded)" do
        result = Subscription.restartable_for_product_and_email(product: product, email: buyer.email)
        expect(result).to be_nil
      end
    end

    context "when the product has been banned (e.g. seller suspension bans every link)" do
      let!(:subscription) do
        create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
      end

      before { product.update!(banned_at: 1.day.ago) }

      it "returns nil (a banned product cannot be restarted)" do
        result = Subscription.restartable_for_product_and_email(product: product, email: buyer.email)
        expect(result).to be_nil
      end
    end
  end

  describe ".active_for_product_and_buyer" do
    context "when product is not a membership" do
      let(:regular_product) { create(:product, user: seller) }

      it "returns nil" do
        expect(Subscription.active_for_product_and_buyer(product: regular_product, buyer: buyer)).to be_nil
      end
    end

    context "when user has an active subscription" do
      let!(:subscription) do
        create_subscription_with_purchase(product: product, purchaser: buyer)
      end

      it "returns the subscription" do
        result = Subscription.active_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to eq(subscription)
      end
    end

    context "when user has a pending cancellation subscription" do
      let!(:subscription) do
        create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          cancelled_at: 1.month.from_now,
          cancelled_by_buyer: true
        )
      end

      it "returns the subscription (still active until cancellation date)" do
        result = Subscription.active_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to eq(subscription)
      end
    end

    context "when user has a cancelled subscription" do
      let!(:subscription) do
        create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
      end

      it "returns nil (not active)" do
        result = Subscription.active_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to be_nil
      end
    end

    context "when user has a failed subscription" do
      let!(:subscription) do
        create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          failed_at: 1.day.ago,
          deactivated_at: 1.day.ago
        )
      end

      it "returns nil (not active)" do
        result = Subscription.active_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to be_nil
      end
    end

    context "when user has no subscription" do
      it "returns nil" do
        result = Subscription.active_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to be_nil
      end
    end

    context "when user has a test subscription" do
      let!(:subscription) do
        create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          is_test_subscription: true
        )
      end

      it "returns nil (test subscriptions are excluded)" do
        result = Subscription.active_for_product_and_buyer(product: product, buyer: buyer)
        expect(result).to be_nil
      end
    end
  end

  describe ".active_for_product_and_email" do
    context "when user has an active subscription" do
      let!(:subscription) do
        create_subscription_with_purchase(product: product, purchaser: buyer)
      end

      it "returns the subscription when matching by email" do
        result = Subscription.active_for_product_and_email(product: product, email: buyer.email)
        expect(result).to eq(subscription)
      end

      it "handles email case insensitivity" do
        result = Subscription.active_for_product_and_email(product: product, email: buyer.email.upcase)
        expect(result).to eq(subscription)
      end
    end

    context "when user has a test subscription" do
      let!(:subscription) do
        create_subscription_with_purchase(
          product: product,
          purchaser: buyer,
          is_test_subscription: true
        )
      end

      it "returns nil (test subscriptions are excluded)" do
        result = Subscription.active_for_product_and_email(product: product, email: buyer.email)
        expect(result).to be_nil
      end
    end
  end

  describe ".lapsed_for_product_and_buyer and .lapsed_for_product_and_email" do
    let!(:cancelled) { create_subscription_with_purchase(product:, purchaser: buyer, cancelled_at: 1.day.ago, deactivated_at: 1.day.ago) }
    let!(:ended) { create_subscription_with_purchase(product:, purchaser: buyer, ended_at: 1.day.ago, deactivated_at: 1.day.ago) }
    let!(:admin_cancelled) { create_subscription_with_purchase(product:, purchaser: buyer, cancelled_at: 1.day.ago, cancelled_by_admin: true, deactivated_at: 1.day.ago) }

    before do
      create_subscription_with_purchase(product:, purchaser: buyer)
      create_subscription_with_purchase(product:, purchaser: buyer, deactivated_at: 1.day.ago, is_test_subscription: true)
      create_subscription_with_purchase(product:, purchaser: create(:user), deactivated_at: 1.day.ago)
      create_subscription_with_purchase(product: create(:membership_product), purchaser: buyer, deactivated_at: 1.day.ago)
    end

    it "includes ended and admin-cancelled subscriptions that are not restartable, and excludes active, test, other buyers and other products" do
      expect(Subscription.restartable_for_product_and_buyer(product:, buyer:)).to eq(cancelled)
      expect(Subscription.lapsed_for_product_and_buyer(product:, buyer:)).to contain_exactly(cancelled, ended, admin_cancelled)
    end

    it "matches by purchase email for a logged-out checkout" do
      expect(Subscription.lapsed_for_product_and_email(product:, email: " #{buyer.email.upcase} ")).to contain_exactly(cancelled, ended, admin_cancelled)
    end

    it "is empty for a non-recurring product" do
      expect(Subscription.lapsed_for_product_and_buyer(product: create(:product), buyer:)).to be_empty
      expect(Subscription.lapsed_for_product_and_email(product: create(:product), email: buyer.email)).to be_empty
    end
  end
end
