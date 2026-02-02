# frozen_string_literal: true

require "spec_helper"

describe Subscription, ".restartable_for_user_and_product", :sidekiq_inline do
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

  context "when product is not a membership" do
    let(:regular_product) { create(:product, user: seller) }

    it "returns nil" do
      expect(Subscription.restartable_for_user_and_product(user_or_email: buyer, product: regular_product)).to be_nil
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

    it "returns the subscription when user is logged in" do
      result = Subscription.restartable_for_user_and_product(user_or_email: buyer, product: product)
      expect(result).to eq(subscription)
    end

    it "returns the subscription when matching by email" do
      result = Subscription.restartable_for_user_and_product(user_or_email: subscription.email, product: product)
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
      result = Subscription.restartable_for_user_and_product(user_or_email: buyer, product: product)
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
      result = Subscription.restartable_for_user_and_product(user_or_email: buyer, product: product)
      expect(result).to be_nil
    end
  end

  context "when subscription has ended (fixed-length completed)" do
    let!(:subscription) do
      create_subscription_with_purchase(
        product: product,
        purchaser: buyer,
        ended_at: 1.day.ago,
        deactivated_at: 1.day.ago
      )
    end

    it "returns nil (not restartable)" do
      result = Subscription.restartable_for_user_and_product(user_or_email: buyer, product: product)
      expect(result).to be_nil
    end
  end

  context "when subscription is active" do
    let!(:subscription) do
      create_subscription_with_purchase(product: product, purchaser: buyer)
    end

    it "returns nil (already active, not restartable)" do
      result = Subscription.restartable_for_user_and_product(user_or_email: buyer, product: product)
      expect(result).to be_nil
    end
  end

  context "when user has no subscription" do
    it "returns nil" do
      result = Subscription.restartable_for_user_and_product(user_or_email: buyer, product: product)
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
      result = Subscription.restartable_for_user_and_product(user_or_email: buyer, product: product)
      expect(result).to eq(newer_subscription)
    end
  end
end

describe Subscription, ".active_for_user_and_product", :sidekiq_inline do
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

  context "when product is not a membership" do
    let(:regular_product) { create(:product, user: seller) }

    it "returns nil" do
      expect(Subscription.active_for_user_and_product(user_or_email: buyer, product: regular_product)).to be_nil
    end
  end

  context "when user has an active subscription" do
    let!(:subscription) do
      create_subscription_with_purchase(product: product, purchaser: buyer)
    end

    it "returns the subscription when user is logged in" do
      result = Subscription.active_for_user_and_product(user_or_email: buyer, product: product)
      expect(result).to eq(subscription)
    end

    it "returns the subscription when matching by email" do
      result = Subscription.active_for_user_and_product(user_or_email: subscription.email, product: product)
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
      result = Subscription.active_for_user_and_product(user_or_email: buyer, product: product)
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
      result = Subscription.active_for_user_and_product(user_or_email: buyer, product: product)
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
      result = Subscription.active_for_user_and_product(user_or_email: buyer, product: product)
      expect(result).to be_nil
    end
  end

  context "when user has no subscription" do
    it "returns nil" do
      result = Subscription.active_for_user_and_product(user_or_email: buyer, product: product)
      expect(result).to be_nil
    end
  end
end
