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

  it "persists one charge presentment and per-purchase presentments whose totals sum exactly to the locked total" do
    purchases = [3_34, 3_33, 3_34].map do |total_transaction_cents|
      create(:purchase,
             link: create(:product, user: seller, price_cents: total_transaction_cents),
             seller:,
             merchant_account:,
             price_cents: total_transaction_cents,
             total_transaction_cents:)
    end
    # 10.01 USD at the 0.8 locked rate is 1251.25 CAD cents; the persisted quote total is
    # the rounded 12.51, which no proportional split of the three items hits exactly —
    # the largest-remainder allocation must still account for every cent.
    locked_quote.canonical_total_cents = 10_01
    locked_quote.presentment_total_cents = 12_51

    result = described_class.new(charge:,
                                 merchant_account:,
                                 purchases:,
                                 amount_cents: 10_01,
                                 gumroad_amount_cents: 3_00,
                                 eligibility_decision:,
                                 locked_quote:).perform

    expect(result).to have_attributes(processor_amount_cents: 12_51,
                                      processor_currency: Currency::CAD,
                                      processor_gumroad_amount_cents: 3_75,
                                      stripe_fx_quote_id: "fxq_locked")

    expect(ChargePresentment.count).to eq(1)
    expect(charge.reload.charge_presentment).to have_attributes(presentment_currency: Currency::CAD,
                                                                presentment_total_cents: 12_51,
                                                                presentment_gumroad_amount_cents: 3_75)

    purchase_presentments = purchases.map { _1.reload.purchase_presentment }
    expect(purchase_presentments).to all(have_attributes(charge_presentment: charge.charge_presentment,
                                                         presentment_currency: Currency::CAD))
    expect(purchase_presentments.sum(&:presentment_total_cents)).to eq(12_51)
    expect(purchase_presentments.sum(&:presentment_gumroad_amount_cents)).to eq(3_75)
  end

  it "falls back without leaving partial presentment records when persistence fails" do
    allow(ErrorNotifier).to receive(:notify)
    allow_any_instance_of(Charge::PresentmentAllocator).to receive(:allocations).and_raise("allocation failed")

    expect(result).to be_nil
    expect(charge.reload.charge_presentment).to be_nil
    expect(purchase.reload.purchase_presentment).to be_nil
    expect(ErrorNotifier).to have_received(:notify).with(instance_of(RuntimeError), context: hash_including(charge_id: charge.id))
  end

  describe "a locked quote that was rounded down" do
    # The quote sized this round-down against the fee it expected Gumroad to collect. By
    # the time the charge runs, that fee is a fact on the purchase rather than a
    # prediction, so the orchestrator re-checks it.
    before do
      locked_quote.presentment_total_cents = 12_49
      locked_quote.rounding_delta_cents = -1
    end

    it "takes the reduction out of Gumroad's share when the fee still covers it" do
      expect(purchase.fee_cents).to be > 0

      expect(result).to have_attributes(processor_amount_cents: 12_49,
                                        processor_gumroad_amount_cents: 3_74)
      expect(charge.reload.charge_presentment).to have_attributes(presentment_total_cents: 12_49,
                                                                  presentment_gumroad_amount_cents: 3_74,
                                                                  rounding_delta_cents: -1)
      expect(purchase.reload.purchase_presentment).to have_attributes(presentment_total_cents: 12_49,
                                                                      presentment_gumroad_amount_cents: 3_74)
    end

    # The waiver (Gumroad Day or the per-seller flag) can begin after the quote was minted,
    # and then there is no percentage fee left to absorb the reduction. Charging anyway
    # would quietly pay the difference out of the seller's proceeds.
    it "refuses the charge, rather than charging the seller, when the fee was waived after the quote was minted" do
      purchase.update!(fee_cents: 0)

      expect(result).to be_nil
      expect(charge.reload.charge_presentment).to be_nil
      expect(purchase.reload.purchase_presentment).to be_nil
    end

    it "reports why it refused so the charge can fail closed with a real reason" do
      purchase.update!(fee_cents: 0)
      orchestrator = described_class.new(charge:,
                                         merchant_account:,
                                         purchases: [purchase],
                                         amount_cents: 10_00,
                                         gumroad_amount_cents: 3_00,
                                         eligibility_decision:,
                                         locked_quote:)

      expect(orchestrator.perform).to be_nil
      expect(orchestrator.fallback_reason).to eq("rounding_delta_exceeds_gumroad_fee")
    end

    it "refuses when the round-down is larger than the fee even though other Gumroad-held money would cover it" do
      # gumroad_amount_cents (3.00 USD → 3.75 CAD) also carries affiliate credit and
      # Gumroad-collected tax, which are owed elsewhere; only the fee can absorb a
      # round-down. A 1.00 CAD reduction clears the former and not the latter.
      purchase.update!(fee_cents: 50)
      locked_quote.presentment_total_cents = 11_50
      locked_quote.rounding_delta_cents = -1_00

      expect(result).to be_nil
    end

    it "still rounds up without consulting the fee at all" do
      purchase.update!(fee_cents: 0)
      locked_quote.presentment_total_cents = 12_99
      locked_quote.rounding_delta_cents = 49

      expect(result).to have_attributes(processor_amount_cents: 12_99,
                                        processor_gumroad_amount_cents: 4_24)
    end
  end
end
