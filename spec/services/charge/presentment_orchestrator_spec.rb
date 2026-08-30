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

  it "persists exact buyer-typed presentment components from the locked quote" do
    purchase.build_tip(value_cents: 3_50, value_usd_cents: 3_50)
    purchase.update!(price_cents: 10_00, total_transaction_cents: 13_50)
    locked_quote.canonical_total_cents = 13_50
    locked_quote.presentment_total_cents = 16_88
    locked_quote.presentment_component_overrides = [[nil, 4_37, nil, nil, nil]]

    expect(result).to have_attributes(processor_amount_cents: 16_88,
                                      processor_currency: Currency::CAD)
    expect(purchase.reload.purchase_presentment).to have_attributes(presentment_price_cents: 12_51,
                                                                    presentment_tip_cents: 4_37,
                                                                    presentment_total_cents: 16_88)
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

  it "persists the exact converted tax on a rounded charge rather than a share of the rounding difference" do
    # The reviewer's case, at the layer where it reaches the receipt: a taxed cart whose
    # total is rounded onto the seller's price ending. The tax row must be what the exact
    # conversion gives, with the whole difference on the price row.
    taxed_purchase = create(:purchase,
                            link: product,
                            seller:,
                            merchant_account:,
                            price_cents: 9_99,
                            gumroad_tax_cents: 1_50,
                            total_transaction_cents: 11_49)
    locked_quote.canonical_total_cents = 11_49
    # 11.49 USD at the 0.8 locked rate converts to exactly 14.36 CAD; the seller's .49
    # ending pulls the charged total to 14.49, a 13-cent increase.
    locked_quote.presentment_total_cents = 14_49
    locked_quote.rounding_delta_cents = 13

    orchestrate = lambda do |quote|
      described_class.new(charge:,
                          merchant_account:,
                          purchases: [taxed_purchase],
                          amount_cents: 11_49,
                          gumroad_amount_cents: 3_00,
                          eligibility_decision:,
                          locked_quote: quote).perform
      taxed_purchase.reload.purchase_presentment
    end

    # The exact leg runs FIRST and only its component numbers are kept: persisting a
    # presentment replaces any existing rows for the charge, so the rounded leg has to be
    # the last one to run for the charge-level assertions below to describe it.
    exact_components = orchestrate.call(locked_quote.dup.tap do |quote|
      quote.presentment_total_cents = 14_36
      quote.rounding_delta_cents = 0
    end).slice(:presentment_price_cents, :presentment_gumroad_tax_cents)
    rounded_row = orchestrate.call(locked_quote)

    # The tax the buyer is told they paid is the same figure whether or not the total was
    # rounded — spreading the difference proportionally instead would report 189 here.
    expect(rounded_row.presentment_gumroad_tax_cents).to eq(exact_components["presentment_gumroad_tax_cents"])
    expect(rounded_row.presentment_gumroad_tax_cents).to eq(1_87)
    expect(rounded_row.presentment_price_cents).to eq(exact_components["presentment_price_cents"] + 13)
    expect(rounded_row.presentment_total_cents).to eq(14_49)
    expect(charge.reload.charge_presentment).to have_attributes(presentment_total_cents: 14_49,
                                                                rounding_delta_cents: 13)
    # Canonical amounts are untouched: the seller is paid from these.
    expect(taxed_purchase.total_transaction_cents).to eq(11_49)
    expect(taxed_purchase.gumroad_tax_cents).to eq(1_50)
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

    # On a sale charged through a Gumroad-owned Stripe account, fee_cents also holds the
    # processor's percentage and fixed costs, which Gumroad only collects on its way to
    # Stripe. A waived sale therefore still shows a positive fee_cents made up entirely of
    # money that is already owed elsewhere, and spending it on a price reduction would mean
    # Gumroad paying Stripe out of pocket.
    it "refuses when the only fee left on a Gumroad-managed charge is the processor's own cost" do
      gumroad_merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
      waived_purchase = create(:purchase,
                               link: product,
                               seller:,
                               merchant_account: gumroad_merchant_account,
                               price_cents: 10_00,
                               total_transaction_cents: 10_00)
      # Turned on after the purchase exists, which is the real sequence being tested: the
      # waiver begins while the buyer is already on the checkout page.
      Feature.activate_user(:waive_gumroad_fee_on_new_sales, seller)
      waived_purchase.send(:calculate_fees)
      waived_purchase.save!

      # The fee is not zero — it is the processor's percentage plus fixed components — which
      # is exactly why reading fee_cents here would have accepted the stale reduction.
      expect(waived_purchase.reload.fee_cents).to be > 0
      expect(waived_purchase.gumroad_percentage_fee_cents).to eq(0)

      orchestrator = described_class.new(charge:,
                                         merchant_account: gumroad_merchant_account,
                                         purchases: [waived_purchase],
                                         amount_cents: 10_00,
                                         gumroad_amount_cents: 3_00,
                                         eligibility_decision:,
                                         locked_quote:)

      expect(orchestrator.perform).to be_nil
      expect(orchestrator.fallback_reason).to eq("rounding_delta_exceeds_gumroad_fee")
      expect(charge.reload.charge_presentment).to be_nil
    end
  end
end
