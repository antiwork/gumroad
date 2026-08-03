# frozen_string_literal: true

require "spec_helper"

# gumroad-private#1434, scope bullet 2 (off-session presentment for UPI Autopay renewals).
#
# The question this measures: for a recurring purchase made on the METHOD-FORCED currency path
# (the path UPI uses — the cart is priced in the local currency and no FX quote is minted), does
# a later charge present in the local currency, or does it fall back to canonical USD?
#
# Answer, measured here: it falls back to USD, and the reason is upstream of the renewal code.
# Charge::MethodForcedPresentment#direct_listed_amount_result persists the presentment with
# fx_rate: nil (asserted in its own spec). Purchase::FixLaterChargePresentmentService reads
# `presentment.charge_presentment.fx_rate` and returns early when it is blank, so NO
# LaterChargePresentment row is ever written. Purchase::LaterChargePresentmentService then hits
# `fallback(:no_stored_presentment)` and the renewal charges canonical USD.
describe "method-forced (UPI-shaped) purchases and later-charge fixing" do
  let(:seller) { create(:user) }
  # Plain :merchant_account, not :merchant_account_stripe. The fixing writer never touches
  # Stripe — it reads the stored presentment — and the onboarding factory calls live Stripe.
  let(:merchant_account) do
    create(:merchant_account, user: seller,
                              charge_processor_merchant_id: "acct_upi1434_#{SecureRandom.hex(6)}")
  end
  let(:product) do
    create(:subscription_product, user: seller, price_currency_type: Currency::INR, price_cents: 500_00)
  end
  let(:subscription) { create(:subscription, link: product, user: create(:user)) }

  def build_forced_currency_purchase(with_fx_rate:)
    purchase = create(:purchase,
                      link: product,
                      seller:,
                      merchant_account:,
                      subscription:,
                      is_original_subscription_purchase: true,
                      displayed_price_cents: 500_00,
                      displayed_price_currency_type: Currency::INR,
                      rate_converted_to_usd: "83.0",
                      price_cents: 602,
                      total_transaction_cents: 602)
    charge = create(:charge,
                    seller:,
                    merchant_account: create(:merchant_account, user: seller,
                                                                charge_processor_merchant_id: "acct_upi1434c_#{SecureRandom.hex(6)}"))
    charge_presentment = create(:charge_presentment,
                                charge:,
                                presentment_currency: Currency::INR,
                                presentment_total_cents: 500_00,
                                presentment_gumroad_amount_cents: 50_00,
                                stripe_fx_quote_id: with_fx_rate.nil? ? nil : "fxq_#{SecureRandom.hex(6)}",
                                stripe_fx_quote_expires_at: with_fx_rate.nil? ? nil : 30.minutes.from_now,
                                fx_rate: with_fx_rate)
    create(:purchase_presentment,
           purchase:,
           charge_presentment:,
           presentment_currency: Currency::INR,
           presentment_price_cents: 500_00,
           presentment_tip_cents: 0,
           presentment_seller_tax_cents: 0,
           presentment_gumroad_tax_cents: 0,
           presentment_shipping_cents: 0,
           presentment_total_cents: 500_00,
           presentment_gumroad_amount_cents: 50_00)
    purchase
  end

  it "writes NO fixing when the method-forced path left fx_rate null, so renewals lose INR" do
    purchase = build_forced_currency_purchase(with_fx_rate: nil)

    Purchase::FixLaterChargePresentmentService.new(purchase:).perform

    expect(subscription.reload.later_charge_presentments).to be_empty

    service = Purchase::LaterChargePresentmentService.new(
      merchant_account:, purchases: [purchase], amount_cents: 602, gumroad_amount_cents: 60
    )
    expect(service.perform).to be_nil
    expect(service.fallback_reason).to eq(:no_stored_presentment)
  end

  it "writes the fixing when an fx_rate IS present, confirming fx_rate is the only blocker" do
    purchase = build_forced_currency_purchase(with_fx_rate: BigDecimal("83.0"))

    Purchase::FixLaterChargePresentmentService.new(purchase:).perform

    fixing = subscription.reload.later_charge_presentments.last
    expect(fixing).to be_present
    expect(fixing.presentment_currency).to eq(Currency::INR)
    expect(fixing.presentment_price_cents).to eq(500_00)
  end
end
