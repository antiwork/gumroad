# frozen_string_literal: true

require "spec_helper"

describe EndSubscriptionWorker, :vcr do
  before do
    @product = create(:subscription_product, user: create(:user), duration_in_months: 1)
    @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product, charge_occurrence_count: 1)
    @purchase = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)
  end

  it "does not call `end_subscription!` on test_subscriptions" do
    @product.user.credit_card = create(:credit_card)
    @product.user.save!
    subscription = create(:subscription, user: @product.user, link: @product)
    subscription.is_test_subscription = true
    subscription.save!
    create(:test_purchase, seller: @product.user, purchaser: @product.user, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription:)
    expect_any_instance_of(Subscription).to_not receive(:end_subscription!)

    described_class.new.perform(subscription.id)
  end

  it "calls `end_subscription!` on subscriptions" do
    expect_any_instance_of(Subscription).to receive(:end_subscription!)

    described_class.new.perform(@subscription.id)
  end

  describe "subscription is cancelled" do
    before do
      @subscription.update_attribute(:cancelled_at, Time.current)
    end

    it "calls `end_subscription!` on subscriptions" do
      expect_any_instance_of(Subscription).to_not receive(:end_subscription!)

      described_class.new.perform(@subscription.id)
    end
  end

  describe "subscription has failed" do
    before do
      @subscription.update_attribute(:failed_at, Time.current)
    end

    it "calls `end_subscription!` on subscriptions" do
      expect_any_instance_of(Subscription).to_not receive(:end_subscription!)

      described_class.new.perform(@subscription.id)
    end
  end

  describe "subscription has ended" do
    before do
      @subscription.update_attribute(:ended_at, Time.current)
    end

    it "calls `end_subscription!` on subscriptions" do
      expect_any_instance_of(Subscription).to_not receive(:end_subscription!)

      described_class.new.perform(@subscription.id)
    end
  end

  describe "subscription hasn't had enough successful charges" do
    before do
      @subscription.update_attribute(:charge_occurrence_count, 2)
    end

    it "calls `end_subscription!` on subscriptions" do
      expect_any_instance_of(Subscription).to_not receive(:end_subscription!)

      described_class.new.perform(@subscription.id)
    end
  end
end
