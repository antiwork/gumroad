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
  let(:quote) do
    StripeFxQuote::Quote.new(id: "fxq_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8"))
  end

  subject(:result) do
    described_class.new(charge:,
                        merchant_account:,
                        purchases: [purchase],
                        amount_cents: 10_00,
                        gumroad_amount_cents: 3_00,
                        eligibility_decision:).perform
  end

  before do
    allow(StripeFxQuote).to receive(:create).and_return(quote)
  end

  it "creates charge and purchase presentments from the locked quote" do
    expect(result).to have_attributes(processor_amount_cents: 12_50,
                                      processor_currency: Currency::CAD,
                                      processor_gumroad_amount_cents: 3_75,
                                      stripe_fx_quote_id: "fxq_test")

    charge_presentment = charge.reload.charge_presentment
    expect(charge_presentment).to have_attributes(processor: StripeChargeProcessor.charge_processor_id,
                                                  presentment_currency: Currency::CAD,
                                                  presentment_total_cents: 12_50,
                                                  presentment_gumroad_amount_cents: 3_75,
                                                  stripe_fx_quote_id: "fxq_test",
                                                  fx_rate: BigDecimal("0.8"))

    purchase_presentment = purchase.reload.purchase_presentment
    expect(purchase_presentment).to have_attributes(charge_presentment:,
                                                    processor: StripeChargeProcessor.charge_processor_id,
                                                    presentment_currency: Currency::CAD,
                                                    presentment_price_cents: 12_50,
                                                    presentment_total_cents: 12_50,
                                                    presentment_gumroad_amount_cents: 3_75)
  end

  it "uses a locked buyer quote total for the processor charge amount" do
    locked_quote = Checkout::BuyerCurrencyQuote::Result.new(
      token: "locked-token",
      currency: Currency::CAD,
      canonical_total_cents: 10_00,
      presentment_total_cents: 12_51,
      fx_rate: BigDecimal("0.8"),
      stripe_fx_quote_id: "fxq_locked",
      stripe_fx_quote_expires_at: 30.minutes.from_now
    )

    expect(StripeFxQuote).not_to receive(:create)

    result = described_class.new(charge:,
                                 merchant_account:,
                                 purchases: [purchase],
                                 amount_cents: 10_00,
                                 gumroad_amount_cents: 3_00,
                                 eligibility_decision:,
                                 locked_quote:).perform

    expect(result).to have_attributes(processor_amount_cents: 12_51,
                                      processor_currency: Currency::CAD,
                                      processor_gumroad_amount_cents: 3_75,
                                      stripe_fx_quote_id: "fxq_locked")
    expect(charge.reload.charge_presentment).to have_attributes(presentment_total_cents: 12_51,
                                                                presentment_gumroad_amount_cents: 3_75,
                                                                stripe_fx_quote_id: "fxq_locked")
    expect(purchase.reload.purchase_presentment).to have_attributes(presentment_price_cents: 12_51,
                                                                    presentment_total_cents: 12_51,
                                                                    presentment_gumroad_amount_cents: 3_75)
  end

  it "falls back without creating presentment records when quote creation fails" do
    allow(ErrorNotifier).to receive(:notify)
    allow(StripeFxQuote).to receive(:create).and_raise(ChargeProcessorUnavailableError.new)

    expect(result).to be_nil
    expect(charge.reload.charge_presentment).to be_nil
    expect(purchase.reload.purchase_presentment).to be_nil
    expect(ErrorNotifier).to have_received(:notify).with(instance_of(ChargeProcessorUnavailableError), context: hash_including(charge_id: charge.id))
  end
end
