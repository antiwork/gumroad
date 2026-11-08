# frozen_string_literal: true

require "spec_helper"

describe Subscription, "#next_charge_price_cents" do
  let(:buyer) { create(:user) }
  let(:purchase) { create(:membership_purchase, purchaser: buyer, email: buyer.email, created_at: Time.current) }
  let(:subscription) { purchase.subscription }
  let(:product) { purchase.link }
  let(:tiers) { [{ "months" => 0, "amount_percentage" => 100 }, { "months" => 12, "amount_percentage" => 0 }] }
  let(:offer_code) { create(:tiered_offer_code, user: product.user, products: [product], ownership_duration_tiers: tiers) }
  let(:full_price) { 5_00 }

  before do
    purchase.update!(offer_code:, displayed_price_cents: 0)
    purchase.create_purchase_offer_code_discount!(
      offer_code:, offer_code_amount: 100, offer_code_is_percent: true,
      pre_discount_minimum_price_cents: full_price
    )
    subscription.reload
  end

  it "keeps the current price at 0 today while pricing the charge date at the later tier" do
    expect(subscription.current_subscription_price_cents).to eq(0)
    expect(subscription.next_charge_price_cents(as_of: 12.months.from_now + 1.day)).to eq(full_price)
  end

  it "keeps the tier boundary exact: 12 months from the purchase is already the later tier" do
    expect(subscription.next_charge_price_cents(as_of: purchase.created_at + 12.months)).to eq(full_price)
  end

  it "prices the charge just before the tier boundary at the earlier tier" do
    expect(subscription.next_charge_price_cents(as_of: 11.months.from_now)).to eq(0)
  end

  it "defaults to the subscription's renewal date" do
    allow(subscription).to receive(:renews_at).and_return(13.months.from_now)
    expect(subscription.next_charge_price_cents).to eq(full_price)
  end

  it "prices a past charge date, or an overdue renewal date, as of now" do
    travel_to(purchase.created_at + 13.months) do
      expect(subscription.renews_at).to be < Time.current
      expect(subscription.next_charge_price_cents(as_of: purchase.created_at + 1.month)).to eq(full_price)
      expect(subscription.next_charge_price_cents).to eq(full_price)
    end
  end

  it "matches the current price for a non-tiered discount" do
    plain = create(:offer_code, user: product.user, products: [product], code: "plain", amount_percentage: 50)
    purchase.update!(offer_code: plain)
    purchase.purchase_offer_code_discount.update!(offer_code: plain, offer_code_amount: 50)
    subscription.reload
    expect(subscription.next_charge_price_cents(as_of: 2.years.from_now)).to eq(subscription.current_subscription_price_cents)
  end

  it "matches the current price without a discount" do
    plain = create(:membership_purchase).subscription
    expect(plain.next_charge_price_cents).to eq(plain.current_subscription_price_cents)
  end

  it "prices a tiered code the seller added after a purchase bought without a discount" do
    other = create(:membership_purchase, purchaser: buyer, email: buyer.email, link: product, created_at: Time.current)
    undiscounted = other.subscription
    expect(other.purchase_offer_code_discount).to be_nil
    other.update!(displayed_price_cents: full_price)
    undiscounted.reload
    expect(undiscounted.current_subscription_price_cents).to eq(0)
    expect(undiscounted.next_charge_price_cents(as_of: 13.months.from_now)).to eq(full_price)
  end

  it "prices a guest buyer (no account) by the original purchase's age" do
    purchase.update!(purchaser: nil)
    subscription.update!(user: nil)
    subscription.reload
    expect(subscription.next_charge_price_cents(as_of: 13.months.from_now)).to eq(full_price)
    expect(subscription.next_charge_price_cents(as_of: 3.months.from_now)).to eq(0)
  end

  it "prices the manage page's next charge for the subscription's account, whoever is viewing" do
    subscription.update!(user: buyer)
    create(:membership_purchase, purchaser: buyer, email: buyer.email, link: product, created_at: 11.months.ago - 1.day)
    expect(subscription.renews_at).to be_within(1.minute).of(1.month.from_now)
    expect(subscription.current_subscription_price_cents).to eq(0)

    { "signed out (reminder token)" => nil, "another signed-in user" => create(:user), "the account owner" => buyer }.each do |viewer_label, viewer|
      props = CheckoutPresenter.new(logged_in_user: viewer, ip: "127.0.0.1").subscription_manager_props(subscription:)
      expect(props[:subscription]).to include(price: 0, next_charge_price: full_price), viewer_label
    end
  end

  context "with an annual plan" do
    let(:purchase) do
      create(:membership_purchase, purchaser: buyer, email: buyer.email, created_at: Time.current,
                                   link: create(:membership_product, subscription_duration: :yearly))
    end

    it "quotes the first renewal at the later tier from the 30-day reminder, while today's tier is still free" do
      expect(subscription.recurrence).to eq(BasePrice::Recurrence::YEARLY)

      travel_to(subscription.renews_at - 30.days) do
        expect(subscription.current_subscription_price_cents).to eq(0)
        expect(subscription.next_charge_price_cents).to eq(full_price)

        mail = CustomerLowPriorityMailer.subscription_renewal_reminder(subscription.id)
        expect(mail.body.encoded).to include("You're paying #{purchase.format_displayed_price_cents(full_price)}")

        value = ReceiptPresenter::PaymentInfo.new(purchase.reload).upcoming_payment_attributes.last[:value]
        expect(value).to start_with("$5 on")

        props = CheckoutPresenter.new(logged_in_user: buyer, ip: "127.0.0.1").subscription_manager_props(subscription: subscription.reload)
        expect(props[:subscription]).to include(price: 0, next_charge_price: full_price)
      end
    end

    it "counts the paid renewal as a future charge for an Indian card mandate while this year is free" do
      expect(subscription.current_subscription_price_cents).to eq(0)
      expect(subscription.future_subscription_charge?).to be(true)
    end

    it "sizes the Indian card mandate for the paid renewal instead of today's $0" do
      expect(purchase.reload).to have_attributes(displayed_price_cents: 0, total_transaction_cents: 0)
      expect(subscription.indian_card_mandate_terms).to include(amount: full_price, currency: Currency::USD, interval: "year")
    end

    it "keeps today's price as the mandate's renewal price for a membership that already pays" do
      paying = create(:membership_purchase, price_cents: 3_00).subscription
      expect(paying.current_subscription_price_cents).to eq(3_00)
      expect(paying.indian_card_mandate_renewal_price_cents).to eq(3_00)
    end

    it "exposes no paid next charge once a single-charge membership has collected it" do
      subscription.update!(charge_occurrence_count: 1)

      props = CheckoutPresenter.new(logged_in_user: buyer, ip: "127.0.0.1").subscription_manager_props(subscription: subscription.reload)
      expect(props[:subscription]).to include(price: 0, next_charge_price: 0, remaining_charges_count: 0)
    end
  end

  describe "surfaces" do
    before { allow(subscription).to receive(:renews_at).and_return(12.months.from_now + 1.day) }

    it "quotes the renewal-date price in the reminder email" do
      allow(Subscription).to receive(:find).with(subscription.id).and_return(subscription)
      mail = CustomerLowPriorityMailer.subscription_renewal_reminder(subscription.id)
      expect(mail.body.encoded).to include(purchase.format_displayed_price_cents(full_price))
      expect(mail.body.encoded).not_to include("You're paying $0")
    end

    it "quotes the renewal-date price on the receipt's upcoming payment line" do
      allow(purchase).to receive(:subscription).and_return(subscription)
      allow(BasePrice::Recurrence).to receive(:seconds_in_recurrence).and_return((12.months + 1.day).to_i)
      value = ReceiptPresenter::PaymentInfo.new(purchase).upcoming_payment_attributes.last[:value]
      expect(value).not_to start_with("$0")
    end

    it "keeps the manage page's current price at 0 and exposes the next charge price" do
      props = CheckoutPresenter.new(logged_in_user: buyer, ip: "127.0.0.1").subscription_manager_props(subscription:)
      expect(props[:subscription]).to include(price: 0, next_charge_price: full_price)
    end
  end
end
