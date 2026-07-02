# frozen_string_literal: true

require "spec_helper"

describe Charge::PresentmentOrchestrator do
  let(:seller) { create(:user) }
  let(:merchant_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:order) { create(:order) }
  let(:charge) { create(:charge, order:, seller:, merchant_account:, amount_cents: 10_00, gumroad_amount_cents: 3_00) }
  let(:product) { create(:product, user: seller, price_cents: 10_00) }
  let(:purchase) do
    create(:purchase,
           link: product,
           seller:,
           merchant_account:,
           price_cents: 10_00,
           total_transaction_cents: 10_00)
  end
  let(:eligibility_decision) do
    Checkout::BuyerCurrencyEligibility::Decision.new(eligible: true, currency: Currency::CAD, fallback_reason: nil)
  end
  let(:locked_quote) do
    Checkout::BuyerCurrencyQuote::Result.new(
      token: "locked-token",
      currency: Currency::CAD,
      canonical_total_cents: 10_00,
      presentment_total_cents: 12_50,
      fx_rate: BigDecimal("0.8"),
      stripe_fx_quote_id: "fxq_locked",
      stripe_fx_quote_expires_at: 30.minutes.from_now
    )
  end

  subject(:result) do
    described_class.new(charge:,
                        merchant_account:,
                        purchases: [purchase],
                        amount_cents: 10_00,
                        gumroad_amount_cents: 3_00,
                        eligibility_decision:,
                        locked_quote:).perform
  end

  it "creates charge and purchase presentments from the locked quote without minting a fresh one" do
    expect(StripeFxQuote).not_to receive(:create)

    expect(result).to have_attributes(processor_amount_cents: 12_50,
                                      processor_currency: Currency::CAD,
                                      processor_gumroad_amount_cents: 3_75,
                                      stripe_fx_quote_id: "fxq_locked")

    charge_presentment = charge.reload.charge_presentment
    expect(charge_presentment).to have_attributes(processor: StripeChargeProcessor.charge_processor_id,
                                                  presentment_currency: Currency::CAD,
                                                  presentment_total_cents: 12_50,
                                                  presentment_gumroad_amount_cents: 3_75,
                                                  stripe_fx_quote_id: "fxq_locked",
                                                  fx_rate: BigDecimal("0.8"))

    purchase_presentment = purchase.reload.purchase_presentment
    expect(purchase_presentment).to have_attributes(charge_presentment:,
                                                    processor: StripeChargeProcessor.charge_processor_id,
                                                    presentment_currency: Currency::CAD,
                                                    presentment_price_cents: 12_50,
                                                    presentment_total_cents: 12_50,
                                                    presentment_gumroad_amount_cents: 3_75)
  end

  it "charges the locked quote total verbatim rather than reconverting the canonical amount" do
    locked_quote.presentment_total_cents = 12_51

    expect(result).to have_attributes(processor_amount_cents: 12_51,
                                      processor_currency: Currency::CAD,
                                      stripe_fx_quote_id: "fxq_locked")
    expect(charge.reload.charge_presentment).to have_attributes(presentment_total_cents: 12_51,
                                                                presentment_gumroad_amount_cents: 3_75,
                                                                stripe_fx_quote_id: "fxq_locked")
    expect(purchase.reload.purchase_presentment).to have_attributes(presentment_price_cents: 12_51,
                                                                    presentment_total_cents: 12_51,
                                                                    presentment_gumroad_amount_cents: 3_75)
  end

  it "falls back without leaving partial presentment records when persistence fails" do
    allow(ErrorNotifier).to receive(:notify)
    allow_any_instance_of(Charge::PresentmentAllocator).to receive(:allocations).and_raise("allocation failed")

    expect(result).to be_nil
    expect(charge.reload.charge_presentment).to be_nil
    expect(purchase.reload.purchase_presentment).to be_nil
    expect(ErrorNotifier).to have_received(:notify).with(instance_of(RuntimeError), context: hash_including(charge_id: charge.id))
  end
end
