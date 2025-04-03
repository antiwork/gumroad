# frozen_string_literal: true

require "spec_helper"

describe UnsubscribeAndFailWorker, :vcr do
  before do
    @product = create(:subscription_product, user: create(:user))
    @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
    @purchase = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)
  end

  it "doesn't call unsubscribe_and_fail on test_subscriptions" do
    @product.user.credit_card = create(:credit_card)
    @product.user.save!
    subscription = create(:subscription, user: @product.user, link: @product)
    subscription.is_test_subscription = true
    subscription.save!
    create(:test_purchase, seller: @product.user, purchaser: @product.user, link: @product, price_cents: @product.price_cents,
                           is_original_subscription_purchase: true, subscription:)
    expect_any_instance_of(Subscription).to_not receive(:unsubscribe_and_fail!)

    described_class.new.perform(subscription.id)
  end

  it "doesn't call unsubscribe_and_fail if last purchase was successful" do
    expect_any_instance_of(Subscription).to_not receive(:charge!)

    described_class.new.perform(@subscription.id)
  end

  it "calls unsubscribe_and_fail when the subscription is overdue for a charge" do
    travel_to @subscription.end_time_of_subscription + 1.hour do
      expect_any_instance_of(Subscription).to receive(:unsubscribe_and_fail!)
      described_class.new.perform(@subscription.id)
    end
  end

  it "does not call unsubscribe_and_fail when the subscription is NOT overdue for a charge" do
    travel_to @subscription.end_time_of_subscription - 1.hour do
      expect_any_instance_of(Subscription).not_to receive(:unsubscribe_and_fail!)
      described_class.new.perform(@subscription.id)
    end
  end

  describe "subscription is cancelled" do
    before do
      @product = create(:product, user: create(:user))
      @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product, cancelled_at: Time.current)
      @purchase = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)
    end

    it "doesn't call unsubscribe_and_fail on subscriptions" do
      expect_any_instance_of(Subscription).to_not receive(:unsubscribe_and_fail!)

      described_class.new.perform(@subscription.id)
    end
  end

  describe "subscription has failed" do
    before do
      @product = create(:product, user: create(:user))
      @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product, failed_at: Time.current)
      @purchase = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)
    end

    it "doesn't call unsubscribe_and_fail on subscriptions" do
      expect_any_instance_of(Subscription).to_not receive(:unsubscribe_and_fail!)

      described_class.new.perform(@subscription.id)
    end
  end
end
