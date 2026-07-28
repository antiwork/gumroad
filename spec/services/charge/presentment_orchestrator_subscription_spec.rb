# frozen_string_literal: true

require "spec_helper"

describe Charge::PresentmentOrchestrator, ".record_subscription_presentment!" do
  let(:seller) { create(:user) }
  let(:product) { create(:membership_product, user: seller, price_cents: 1000) }
  let(:subscription) { create(:subscription, link: product, user: create(:user)) }

  def allocation_for(purchase, price_cents: 899)
    Charge::PresentmentAllocator::Allocation.new(
      purchase:,
      presentment_price_cents: price_cents,
      presentment_tip_cents: 0,
      presentment_seller_tax_cents: 0,
      presentment_gumroad_tax_cents: 0,
      presentment_shipping_cents: 0,
      presentment_total_cents: price_cents,
      presentment_gumroad_amount_cents: 100
    )
  end

  def record(purchase, price_cents: 899, fx_rate: 0.9)
    described_class.record_subscription_presentment!(
      allocation: allocation_for(purchase, price_cents:),
      presentment_currency: "eur",
      fx_rate:
    )
  end

  it "stores the fixed amount from the signup charge so renewals have something to reuse" do
    signup = create(:membership_purchase, link: product, seller:, subscription:,
                                          is_original_subscription_purchase: true)

    record(signup)

    stored = subscription.reload.subscription_presentment
    expect(stored).to be_present
    expect(stored.presentment_currency).to eq("eur")
    expect(stored.presentment_price_cents).to eq(899)
    expect(stored.signup_exchange_rate).to eq(0.9)
  end

  it "stores the PRICE component, not the total, because tax and shipping move per renewal" do
    signup = create(:membership_purchase, link: product, seller:, subscription:,
                                          is_original_subscription_purchase: true)
    allocation = allocation_for(signup, price_cents: 899)
    allocation.presentment_seller_tax_cents = 150
    allocation.presentment_total_cents = 1049

    described_class.record_subscription_presentment!(allocation:, presentment_currency: "eur", fx_rate: 0.9)

    expect(subscription.reload.subscription_presentment.presentment_price_cents).to eq(899)
  end

  it "is idempotent so a retried charge does not violate the unique index" do
    signup = create(:membership_purchase, link: product, seller:, subscription:,
                                          is_original_subscription_purchase: true)

    record(signup)
    expect { record(signup, price_cents: 1234) }.not_to raise_error

    # The first write wins: a retry must not silently reprice an existing subscription.
    expect(subscription.reload.subscription_presentment.presentment_price_cents).to eq(899)
  end

  it "does not write for a renewal, which reuses the stored amount rather than setting it" do
    # A renewal purchase can only be validated once the subscription has its original
    # purchase (Subscription#current_subscription_price_cents reads it).
    create(:membership_purchase, link: product, seller:, subscription:,
                                 is_original_subscription_purchase: true)
    renewal = create(:membership_purchase, link: product, seller:, subscription:,
                                           is_original_subscription_purchase: false)

    record(renewal)

    expect(subscription.reload.subscription_presentment).to be_nil
  end

  it "does not write for a non-subscription purchase" do
    one_off = create(:purchase, link: create(:product, user: seller), seller:)

    expect { record(one_off) }.not_to change(SubscriptionPresentment, :count)
  end

  it "does not write without an fx rate, which would leave drift unattributable" do
    signup = create(:membership_purchase, link: product, seller:, subscription:,
                                          is_original_subscription_purchase: true)

    record(signup, fx_rate: nil)

    expect(subscription.reload.subscription_presentment).to be_nil
  end

  it "does not write a non-positive price, which the model would reject anyway" do
    signup = create(:membership_purchase, link: product, seller:, subscription:,
                                          is_original_subscription_purchase: true)

    record(signup, price_cents: 0)

    expect(subscription.reload.subscription_presentment).to be_nil
  end
end
