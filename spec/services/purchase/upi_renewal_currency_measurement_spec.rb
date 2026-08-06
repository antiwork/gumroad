# frozen_string_literal: true

require "spec_helper"

# gumroad-private#1434, scope bullet 2 (off-session presentment for UPI Autopay renewals).
#
# The question this measures: for a recurring purchase made on the METHOD-FORCED currency path
# (the path UPI uses — the cart is priced in the local currency and no FX quote is minted), does
# a later charge present in the local currency, or does it fall back to canonical USD?
#
# Answer on main was USD: Charge::MethodForcedPresentment#direct_listed_amount_result persists
# the presentment with fx_rate: nil, and the fixing writer returned early on a blank fx_rate, so
# no LaterChargePresentment row was ever written. This branch closes that gap for direct-listed
# products: when fx_rate is blank but the product is priced in the presentment currency, the
# fixing is derived from the purchase's stored product rate instead, so renewals keep INR.
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

  it "writes the fixing from the stored product rate when the method-forced path left fx_rate null, so renewals keep INR" do
    purchase = build_forced_currency_purchase(with_fx_rate: nil)

    Purchase::FixLaterChargePresentmentService.new(purchase:).perform

    fixing = subscription.reload.later_charge_presentments.sole
    expect(fixing.presentment_currency).to eq(Currency::INR)
    expect(fixing.presentment_price_cents).to eq(500_00)
    expect(fixing.signup_currency_units_per_usd).to be_within(0.001).of(83)

    # Read the renewal side with a renewal-shaped purchase. The original signup purchase would
    # skip the stored fixing for a different reason (later_charge_owner nils out originals),
    # which would mask the fixing's existence.
    renewal = create(:purchase,
                     link: product,
                     seller:,
                     merchant_account:,
                     subscription:,
                     is_original_subscription_purchase: false,
                     price_cents: 602,
                     total_transaction_cents: 602)
    service = Purchase::LaterChargePresentmentService.new(
      merchant_account:, purchases: [renewal], amount_cents: 602, gumroad_amount_cents: 60
    )
    service.perform
    expect(service.fallback_reason).not_to eq(:no_stored_presentment)
  end

  it "writes the fixing when an fx_rate IS present, confirming fx_rate is the only blocker to the fixing being written" do
    purchase = build_forced_currency_purchase(with_fx_rate: BigDecimal("83.0"))

    Purchase::FixLaterChargePresentmentService.new(purchase:).perform

    fixing = subscription.reload.later_charge_presentments.last
    expect(fixing).to be_present
    expect(fixing.presentment_currency).to eq(Currency::INR)
    expect(fixing.presentment_price_cents).to eq(500_00)
  end
end
