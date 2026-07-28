# frozen_string_literal: true

require "spec_helper"

describe Subscription::PresentmentRenewal do
  let(:seller) { create(:user) }
  let(:merchant_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:product) { create(:membership_product, user: seller, price_cents: 1000) }
  let(:subscription) { create(:subscription, link: product, user: create(:user)) }
  let(:original_purchase) do
    create(:membership_purchase, link: product, seller:, subscription:,
                                 is_original_subscription_purchase: true, price_cents: 1000)
  end
  let(:renewal_purchase) do
    # The membership_purchase factory flags purchases as the original subscription purchase by
    # default, so a renewal has to clear that bit explicitly — RecurringChargeWorker's charges
    # are exactly the ones without it (Purchase.recurring_charge scope).
    create(:membership_purchase, link: product, seller:, subscription:, price_cents: 1000,
                                 is_original_subscription_purchase: false)
  end
  let(:charge) { create(:charge, seller:, merchant_account:) }

  # EUR 8.99 stored at signup, signup rate 1.111... EUR per USD (the reciprocal of a 0.9
  # USD-per-EUR quote). Dated in the past so the newest-effective ordering is deterministic.
  let!(:stored) do
    create(:subscription_presentment, subscription:, presentment_currency: "eur",
                                      presentment_price_cents: 899,
                                      signup_currency_units_per_usd: BigDecimal("1.111111111111111"),
                                      effective_from: 30.days.ago)
  end

  let(:quote) { double(id: "fxq_test_1", fx_rate: 0.8, expires_at: 1.day.from_now) }

  def service(purchases: [renewal_purchase], amount_cents: 1000, gumroad_amount_cents: 100)
    described_class.new(charge:, merchant_account:, purchases:, amount_cents:, gumroad_amount_cents:)
  end

  before do
    original_purchase
    allow(StripeFxQuote).to receive(:create).and_return(quote)
    allow(Checkout::BuyerCurrencyEligibility).to receive(:usd_settling_merchant_account?).and_return(true)
    allow(StripeChargeProcessor).to receive(:charge_minor_units_compatible?).and_return(true)
  end

  it "charges the amount stored at signup rather than one derived from the current rate" do
    result = service.perform

    expect(result).to be_present
    expect(result.processor_currency).to eq("eur")
    # The rate moved from 0.9 to 0.8; the member still pays exactly what they agreed to.
    expect(result.processor_amount_cents).to eq(899)
  end

  it "reads the newest fixing that has taken effect, so a price change is honoured" do
    create(:subscription_presentment, subscription:, presentment_currency: "eur",
                                      presentment_price_cents: 1299,
                                      effective_from: 1.hour.ago)

    expect(service.perform.processor_amount_cents).to eq(1299)
  end

  it "ignores a future-dated fixing, so a scheduled price change does not bill early" do
    create(:subscription_presentment, subscription:, presentment_currency: "eur",
                                      presentment_price_cents: 1299,
                                      effective_from: 3.days.from_now)

    expect(service.perform.processor_amount_cents).to eq(899)
  end

  it "does not move the charged amount when the rate moves" do
    amounts = [0.5, 0.9, 1.4].map do |rate|
      allow(StripeFxQuote).to receive(:create).and_return(double(id: "fxq", fx_rate: rate, expires_at: 1.day.from_now))
      charge.charge_presentment&.destroy!
      service.perform.processor_amount_cents
    end

    expect(amounts.uniq).to eq([899])
  end

  it "mints a fresh quote for every renewal rather than reusing the signup quote" do
    expect(StripeFxQuote).to receive(:create).once.and_return(quote)

    service.perform
  end

  it "persists the presentment so receipts and accounting read one stored figure" do
    service.perform

    presentment = renewal_purchase.reload.purchase_presentment
    expect(presentment).to be_present
    expect(presentment.presentment_currency).to eq("eur")
    expect(presentment.presentment_total_cents).to eq(899)
  end

  it "converts tax at today's rate instead of freezing it with the price" do
    renewal_purchase.update!(tax_cents: 0, gumroad_tax_cents: 0, shipping_cents: 0)
    baseline = service.perform.processor_amount_cents
    expect(baseline).to eq(899)

    charge.reload.charge_presentment&.destroy!
    renewal_purchase.update!(tax_cents: 100)

    result = service.perform

    # The price stays fixed at 899 while tax moves with the market. The quote is minted
    # from_currency EUR to_currency USD, so fx_rate 0.8 means 1 EUR buys 0.80 USD — $1.00 of
    # tax is therefore EUR 1.25 (100 / 0.8), not EUR 0.80. Getting this direction backwards
    # is the easy mistake here, so the number is spelled out rather than reused from the code.
    expect(result.processor_amount_cents).to eq(899 + 125)
  end

  context "when the subscription has no stored amount" do
    let!(:stored) { nil }

    it "falls back to canonical USD rather than inventing a local amount" do
      renewal = service

      expect(renewal.perform).to be_nil
      expect(renewal.fallback_reason).to eq(:no_stored_presentment)
    end
  end

  it "falls back rather than failing the renewal when the quote cannot be minted" do
    allow(StripeFxQuote).to receive(:create).and_return(nil)
    renewal = service

    expect(renewal.perform).to be_nil
    expect(renewal.fallback_reason).to eq(:quote_unavailable)
  end

  it "falls back rather than raising when the processor errors" do
    allow(StripeFxQuote).to receive(:create).and_raise(StandardError, "stripe down")
    expect(ErrorNotifier).to receive(:notify)

    expect(service.perform).to be_nil
  end

  it "ignores the signup charge, which establishes the amount rather than reusing it" do
    signup_service = service(purchases: [original_purchase])

    expect(signup_service.perform).to be_nil
    expect(signup_service.fallback_reason).to eq(:no_stored_presentment)
  end

  it "ignores a multi-purchase charge, a shape it has not reasoned about" do
    other = create(:membership_purchase, link: product, seller:, subscription:,
                                         is_original_subscription_purchase: false)

    expect(service(purchases: [renewal_purchase, other]).perform).to be_nil
  end

  it "keeps the persisted components summing to the total when conversion rounds" do
    renewal_purchase.update!(tax_cents: 33, shipping_cents: 17)

    service.perform

    presentment = renewal_purchase.reload.purchase_presentment
    components = presentment.presentment_price_cents + presentment.presentment_tip_cents +
                 presentment.presentment_seller_tax_cents + presentment.presentment_gumroad_tax_cents +
                 presentment.presentment_shipping_cents
    expect(components).to eq(presentment.presentment_total_cents)
  end
end
