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

  it "keeps access active when an Indian card mandate update is required",
     vcr: { cassette_name: "UnsubscribeAndFailWorker/calls_unsubscribe_and_fail_when_the_subscription_is_overdue_for_a_charge" } do
    Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @product.user)
    @subscription.update_flag!(:renewal_disabled_due_to_indian_card_mandate, true, true)

    travel_to @subscription.end_time_of_subscription + 1.hour do
      expect_any_instance_of(Subscription).to receive(:unsubscribe_and_fail!).and_call_original
      described_class.new.perform(@subscription.id)
    end

    expect(@subscription.reload).to be_alive
    expect(@subscription.failed_at).to be_nil
  ensure
    Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @product.user)
  end

  it "keeps access active for a mandate failure queued before the stop existed",
     vcr: { cassette_name: "UnsubscribeAndFailWorker/calls_unsubscribe_and_fail_when_the_subscription_is_overdue_for_a_charge" } do
    Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @product.user)
    card = @subscription.credit_card_to_charge
    card.update!(card_country: Compliance::Countries::IND.alpha2)
    paid_through = @subscription.end_time_of_last_paid_period
    create(
      :purchase,
      link: @product,
      seller: @product.user,
      purchaser: @subscription.user,
      subscription: @subscription,
      credit_card: card,
      purchase_state: "failed",
      error_code: PurchaseErrorCode::INDIA_CARD_MANDATE_MISSING,
      created_at: paid_through + 1.minute
    )

    travel_to paid_through + 1.hour do
      described_class.new.perform(@subscription.id)
    end

    expect(@subscription.reload).to be_alive
    expect(@subscription.failed_at).to be_nil
    expect(@subscription).to be_renewal_disabled_due_to_indian_card_mandate
  ensure
    Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @product.user)
  end

  it "queues the overdue charge when the mandate has recovered",
     vcr: { cassette_name: "UnsubscribeAndFailWorker/calls_unsubscribe_and_fail_when_the_subscription_is_overdue_for_a_charge" } do
    Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @product.user)
    card = @subscription.credit_card_to_charge
    card.update!(card_country: Compliance::Countries::IND.alpha2)
    paid_through = @subscription.end_time_of_last_paid_period
    create(
      :purchase,
      link: @product,
      seller: @product.user,
      purchaser: @subscription.user,
      subscription: @subscription,
      credit_card: card,
      purchase_state: "failed",
      error_code: PurchaseErrorCode::INDIA_CARD_MANDATE_MISSING,
      created_at: paid_through + 1.minute
    )
    allow_any_instance_of(Subscription).to receive(:refresh_indian_card_mandate!) do |subscription|
      subscription.update_flag!(:renewal_disabled_due_to_indian_card_mandate, false, true)
      "active"
    end
    expect(RecurringChargeWorker).to receive(:perform_async).with(@subscription.id)

    travel_to paid_through + 1.hour do
      described_class.new.perform(@subscription.id)
    end

    expect(@subscription.reload).to be_alive
    expect(@subscription).not_to be_renewal_disabled_due_to_indian_card_mandate
  ensure
    Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @product.user)
  end

  it "does not reuse an old mandate failure after an ordinary decline",
     vcr: { cassette_name: "UnsubscribeAndFailWorker/calls_unsubscribe_and_fail_when_the_subscription_is_overdue_for_a_charge" } do
    Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @product.user)
    card = @subscription.credit_card_to_charge
    card.update!(card_country: Compliance::Countries::IND.alpha2)
    paid_through = @subscription.end_time_of_last_paid_period
    create(
      :purchase,
      link: @product,
      seller: @product.user,
      purchaser: @subscription.user,
      subscription: @subscription,
      credit_card: card,
      purchase_state: "failed",
      error_code: PurchaseErrorCode::INDIA_CARD_MANDATE_MISSING,
      created_at: paid_through + 1.minute
    )
    create(
      :purchase,
      link: @product,
      seller: @product.user,
      purchaser: @subscription.user,
      subscription: @subscription,
      credit_card: card,
      purchase_state: "failed",
      error_code: PurchaseErrorCode::STRIPE_INSUFFICIENT_FUNDS,
      created_at: paid_through + 2.minutes
    )
    expect_any_instance_of(Subscription).not_to receive(:refresh_indian_card_mandate!)
    expect(RecurringChargeWorker).not_to receive(:perform_async)

    travel_to paid_through + 1.hour do
      described_class.new.perform(@subscription.id)
    end

    expect(@subscription.reload).not_to be_alive
    expect(@subscription.failed_at).to be_present
  ensure
    Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @product.user)
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
