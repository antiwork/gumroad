# frozen_string_literal: true

require "spec_helper"

describe Purchase::PresentmentRefund do
  let(:product) { create(:product, price_cents: 100) }

  let(:purchase) do
    build(:purchase,
          link: product,
          price_cents: 100,
          total_transaction_cents: 100,
          purchase_state: "successful").tap { _1.save!(validate: false) }
  end

  before do
    create(:purchase_presentment,
           purchase:,
           presentment_currency: Currency::CAD,
           presentment_price_cents: 100,
           presentment_tip_cents: 10,
           presentment_seller_tax_cents: 5,
           presentment_gumroad_tax_cents: 20,
           presentment_shipping_cents: 0,
           presentment_total_cents: 135)
  end

  it "returns nil for canonical purchases" do
    purchase.purchase_presentment.destroy!
    purchase.association(:purchase_presentment).reset

    expect(described_class.new(purchase:, canonical_gross_refund_cents: 50).result).to be_nil
  end

  it "computes a full remaining presentment refund snapshot" do
    result = described_class.new(purchase:, canonical_gross_refund_cents: 100).result

    expect(result.json_data).to eq(
      presentment_currency: Currency::CAD,
      presentment_amount_cents: 135,
      presentment_price_cents: 100,
      presentment_tip_cents: 10,
      presentment_seller_tax_cents: 5,
      presentment_gumroad_tax_cents: 20,
      presentment_shipping_cents: 0
    )
  end

  it "computes a partial presentment refund by the canonical refund ratio" do
    result = described_class.new(purchase:, canonical_gross_refund_cents: 40).result

    expect(result.presentment_amount_cents).to eq(54)
    expect([
      result.presentment_price_cents,
      result.presentment_tip_cents,
      result.presentment_seller_tax_cents,
      result.presentment_gumroad_tax_cents,
      result.presentment_shipping_cents,
    ].sum).to eq(result.presentment_amount_cents)
  end

  it "clamps the final refund to the exact remaining presentment cents" do
    refund = build(:refund, purchase:, total_transaction_cents: 40, amount_cents: 40)
    refund.presentment_currency = Currency::CAD
    refund.presentment_amount_cents = 54
    refund.presentment_price_cents = 40
    refund.presentment_tip_cents = 4
    refund.presentment_seller_tax_cents = 2
    refund.presentment_gumroad_tax_cents = 8
    refund.presentment_shipping_cents = 0
    purchase.refunds << refund

    result = described_class.new(purchase:, canonical_gross_refund_cents: 60).result

    expect(result.presentment_amount_cents).to eq(81)
    expect(result.presentment_price_cents).to eq(60)
    expect(result.presentment_tip_cents).to eq(6)
    expect(result.presentment_seller_tax_cents).to eq(3)
    expect(result.presentment_gumroad_tax_cents).to eq(12)
    expect(result.presentment_shipping_cents).to eq(0)
  end

  def component_values(result)
    [
      result.presentment_price_cents,
      result.presentment_tip_cents,
      result.presentment_seller_tax_cents,
      result.presentment_gumroad_tax_cents,
      result.presentment_shipping_cents,
    ]
  end

  def record_presentment_refund!(canonical_cents:, result:)
    refund = build(:refund, purchase:, total_transaction_cents: canonical_cents, amount_cents: canonical_cents)
    result.json_data.each { |key, value| refund.public_send("#{key}=", value) }
    purchase.refunds << refund
    refund
  end

  # Seller-path trap: three equal 33-canonical partials on 100 canonical / 135
  # presentment. Allocating each against ORIGINAL totals yields 45+45+45=135
  # presentment while 1 canonical cent remains (and drives component remainders
  # negative). Allocating against REMAINING balances leaves 1 presentment cent
  # for that last canonical cent.
  it "allocates repeated seller partials against remaining balances so the last canonical cent stays refundable" do
    presentment_refunded = 0
    components_refunded = [0, 0, 0, 0, 0]

    3.times do
      result = described_class.new(purchase:, canonical_gross_refund_cents: 33).result
      expect(result).to be_present
      expect(result.presentment_amount_cents).to be_positive
      expect(component_values(result).sum).to eq(result.presentment_amount_cents)
      expect(component_values(result)).to all(be >= 0)

      record_presentment_refund!(canonical_cents: 33, result:)
      presentment_refunded += result.presentment_amount_cents
      components_refunded = components_refunded.zip(component_values(result)).map(&:sum)
    end

    expect(presentment_refunded).to eq(134)
    expect(presentment_refunded).to be < 135
    expect(purchase.gross_amount_refundable_cents).to eq(1)
    expect(components_refunded).to all(be >= 0)
    expect(components_refunded.sum).to eq(134)

    original_components = [
      purchase.purchase_presentment.presentment_price_cents,
      purchase.purchase_presentment.presentment_tip_cents,
      purchase.purchase_presentment.presentment_seller_tax_cents,
      purchase.purchase_presentment.presentment_gumroad_tax_cents,
      purchase.purchase_presentment.presentment_shipping_cents,
    ]
    expect(original_components.zip(components_refunded).map { |o, r| o - r }).to all(be >= 0)

    final = described_class.new(purchase:, canonical_gross_refund_cents: 1).result
    expect(final.presentment_amount_cents).to eq(1)
    expect(component_values(final).sum).to eq(1)
    expect(component_values(final)).to all(be >= 0)
    expect(presentment_refunded + final.presentment_amount_cents).to eq(135)
    expect(components_refunded.zip(component_values(final)).map(&:sum)).to eq(original_components)
  end

  it "keeps seller-path partial component allocation inside remaining component balances" do
    # Three equal partials against ORIGINAL component weights over-allocate seller
    # tax and Gumroad tax (negative remainders). Remaining-weight allocation stays
    # inside each component's leftover balance.
    3.times do
      result = described_class.new(purchase:, canonical_gross_refund_cents: 33).result
      remaining_before = described_class::COMPONENT_KEYS.map do |key|
        purchase.purchase_presentment.public_send(key).to_i -
          purchase.refunds.effective.sum { _1.public_send(key).to_i }
      end

      expect(component_values(result).zip(remaining_before).all? { |got, rem| got <= rem }).to eq(true)
      expect(component_values(result)).to all(be >= 0)
      expect(component_values(result).sum).to eq(result.presentment_amount_cents)

      record_presentment_refund!(canonical_cents: 33, result:)
    end

    remaining_after = described_class::COMPONENT_KEYS.map do |key|
      purchase.purchase_presentment.public_send(key).to_i -
        purchase.refunds.effective.sum { _1.public_send(key).to_i }
    end
    expect(remaining_after).to all(be >= 0)
    expect(remaining_after.sum).to eq(1)
  end

  it "leaves a positive presentment amount for the final one-cent seller refund after three 33-cent partials" do
    3.times do
      result = described_class.new(purchase:, canonical_gross_refund_cents: 33).result
      record_presentment_refund!(canonical_cents: 33, result:)
    end

    expect(purchase.gross_amount_refundable_cents).to eq(1)
    leftover_presentment = purchase.purchase_presentment.presentment_total_cents -
      purchase.refunds.effective.sum { _1.presentment_amount_cents.to_i }
    expect(leftover_presentment).to eq(1)

    final = described_class.new(purchase:, canonical_gross_refund_cents: 1).result
    expect(final.presentment_amount_cents).to eq(1)
    expect(component_values(final).sum).to eq(1)
    expect(component_values(final)).to all(be >= 0)
  end

  it "returns nil for a seller partial when a prior refund has no presentment snapshot" do
    # Remaining-balance math would otherwise over-size the presentment refund
    # (canonical already reduced; presentment remaining still looks full).
    refund = build(:refund, purchase:, total_transaction_cents: 40, amount_cents: 40)
    purchase.refunds << refund
    expect(refund.presentment_amount_cents.to_i).to eq(0)
    expect(purchase.gross_amount_refundable_cents).to eq(60)

    expect(described_class.new(purchase:, canonical_gross_refund_cents: 30).result).to be_nil
  end

  it "returns nil when presentment cents are already exhausted but canonical refundable remains" do
    # Legacy stuck state from original-weight allocation: presentment fully refunded,
    # 1 canonical cent left. Fail closed instead of returning a zero-amount Result.
    3.times do
      refund = build(:refund, purchase:, total_transaction_cents: 33, amount_cents: 33)
      refund.presentment_currency = Currency::CAD
      refund.presentment_amount_cents = 45
      refund.presentment_price_cents = 33
      refund.presentment_tip_cents = 3
      refund.presentment_seller_tax_cents = 2
      refund.presentment_gumroad_tax_cents = 7
      refund.presentment_shipping_cents = 0
      purchase.refunds << refund
    end
    expect(purchase.gross_amount_refundable_cents).to eq(1)
    expect(
      purchase.purchase_presentment.presentment_total_cents -
        purchase.refunds.effective.sum { _1.presentment_amount_cents.to_i }
    ).to eq(0)

    expect(described_class.new(purchase:, canonical_gross_refund_cents: 1).result).to be_nil
  end

  describe "#tax_only_result" do
    it "returns nil for canonical purchases" do
      purchase.purchase_presentment.destroy!
      purchase.association(:purchase_presentment).reset

      expect(described_class.new(purchase:, canonical_gross_refund_cents: 20).tax_only_result).to be_nil
    end

    it "builds a tax-only snapshot for the remaining presentment Gumroad tax" do
      result = described_class.new(purchase:, canonical_gross_refund_cents: 20).tax_only_result

      expect(result.json_data).to eq(
        presentment_currency: Currency::CAD,
        presentment_amount_cents: 20,
        presentment_price_cents: 0,
        presentment_tip_cents: 0,
        presentment_seller_tax_cents: 0,
        presentment_gumroad_tax_cents: 20,
        presentment_shipping_cents: 0
      )
    end

    it "excludes presentment tax cents already refunded" do
      refund = build(:refund, purchase:, total_transaction_cents: 40, amount_cents: 40)
      refund.presentment_currency = Currency::CAD
      refund.presentment_amount_cents = 54
      refund.presentment_gumroad_tax_cents = 8
      purchase.refunds << refund

      result = described_class.new(purchase:, canonical_gross_refund_cents: 12).tax_only_result

      expect(result.presentment_amount_cents).to eq(12)
      expect(result.presentment_gumroad_tax_cents).to eq(12)
    end

    it "returns nil when no presentment tax remains" do
      purchase.purchase_presentment.update!(presentment_gumroad_tax_cents: 0,
                                            presentment_price_cents: 120,
                                            presentment_total_cents: 135)
      purchase.association(:purchase_presentment).reset

      expect(described_class.new(purchase:, canonical_gross_refund_cents: 20).tax_only_result).to be_nil
    end

    it "fails closed when a prior refund lacks a presentment snapshot" do
      # A snapshotless refund reduced the canonical tax refundable amount but counts as
      # zero presentment cents, so the remaining buyer-currency tax cannot be computed.
      refund = build(:refund, purchase:, total_transaction_cents: 40, amount_cents: 40)
      purchase.refunds << refund

      expect(described_class.new(purchase:, canonical_gross_refund_cents: 20).tax_only_result).to be_nil
    end

    # The compliance invariant behind buyer-currency VAT invoices: the buyer-currency tax
    # figure printed on the invoice is what a tax authority reads, so a standalone VAT
    # refund must send back exactly that amount, not a re-derived or canonical figure.
    it "sends exactly the buyer-currency tax amount the invoice claims" do
      # This purchase is deliberately persisted without validation (no real charge), so
      # skip validations here too.
      purchase.was_purchase_taxable = true
      purchase.gumroad_tax_cents = 20
      purchase.save!(validate: false)
      invoiced_tax_cents = purchase.buyer_presentment_non_refunded_tax_cents
      refund_amount_cents = described_class
                              .new(purchase:, canonical_gross_refund_cents: purchase.gumroad_tax_refundable_cents)
                              .tax_only_result
                              .presentment_amount_cents

      # 5 seller tax + 20 Gumroad tax are both on the invoice's single tax line, but only
      # the Gumroad-remitted 20 is ours to refund; the seller's 5 stays with the seller.
      expect(invoiced_tax_cents).to eq(25)
      expect(refund_amount_cents).to eq(20)
      expect(purchase.purchase_presentment.presentment_gumroad_tax_cents).to eq(refund_amount_cents)

      # And once that refund is recorded, the invoice stops claiming the refunded portion.
      refund = build(:refund, purchase:, total_transaction_cents: 20, amount_cents: 0, gumroad_tax_cents: 20)
      refund.presentment_currency = Currency::CAD
      refund.presentment_amount_cents = refund_amount_cents
      refund.presentment_gumroad_tax_cents = refund_amount_cents
      purchase.refunds << refund
      purchase.reload

      expect(purchase.buyer_presentment_non_refunded_tax_cents).to eq(invoiced_tax_cents - refund_amount_cents)
      expect(purchase.buyer_presentment_non_refunded_total_cents).to eq(135 - refund_amount_cents)
    end
  end

  describe ".from_presentment_amount" do
    it "returns nil for canonical purchases" do
      purchase.purchase_presentment.destroy!
      purchase.association(:purchase_presentment).reset

      expect(described_class.from_presentment_amount(purchase:, presentment_amount_cents: 135)).to be_nil
    end

    it "derives the full canonical refund when the presentment amount equals the remaining total" do
      derived = described_class.from_presentment_amount(purchase:, presentment_amount_cents: 135)

      expect(derived.canonical_gross_refund_cents).to eq(purchase.gross_amount_refundable_cents)
      expect(derived.presentment_refund.presentment_amount_cents).to eq(135)
      expect(derived.presentment_refund.currency).to eq(Currency::CAD)
    end

    it "derives a proportional canonical refund for a partial presentment amount" do
      derived = described_class.from_presentment_amount(purchase:, presentment_amount_cents: 54)

      expect(derived.canonical_gross_refund_cents).to eq(40)
      expect(derived.presentment_refund.presentment_amount_cents).to eq(54)
      expect([
        derived.presentment_refund.presentment_price_cents,
        derived.presentment_refund.presentment_tip_cents,
        derived.presentment_refund.presentment_seller_tax_cents,
        derived.presentment_refund.presentment_gumroad_tax_cents,
        derived.presentment_refund.presentment_shipping_cents,
      ].sum).to eq(54)
    end

    it "returns nil when the presentment amount exceeds the remaining presentment cents" do
      refund = build(:refund, purchase:, total_transaction_cents: 40, amount_cents: 40)
      refund.presentment_currency = Currency::CAD
      refund.presentment_amount_cents = 54
      purchase.refunds << refund

      expect(described_class.from_presentment_amount(purchase:, presentment_amount_cents: 100)).to be_nil
    end

    it "allocates repeated partials against remaining balances so the final presentment cent stays recordable" do
      purchase.purchase_presentment.update!(presentment_price_cents: 101,
                                            presentment_tip_cents: 0,
                                            presentment_seller_tax_cents: 0,
                                            presentment_gumroad_tax_cents: 0,
                                            presentment_total_cents: 101,
                                            # The factory default (135) would exceed this small total and
                                            # fail the gumroad-amount capacity validation.
                                            presentment_gumroad_amount_cents: 10)
      purchase.association(:purchase_presentment).reset

      first = described_class.from_presentment_amount(purchase:, presentment_amount_cents: 50)
      expect(first.canonical_gross_refund_cents).to eq(50)
      first_refund = build(:refund, purchase:, total_transaction_cents: 50, amount_cents: 50)
      first.presentment_refund.json_data.each { |key, value| first_refund.public_send("#{key}=", value) }
      purchase.refunds << first_refund

      second = described_class.from_presentment_amount(purchase:, presentment_amount_cents: 50)
      expect(second.canonical_gross_refund_cents).to be < 50
      second_refund = build(:refund, purchase:, total_transaction_cents: second.canonical_gross_refund_cents, amount_cents: second.canonical_gross_refund_cents)
      second.presentment_refund.json_data.each { |key, value| second_refund.public_send("#{key}=", value) }
      purchase.refunds << second_refund

      final = described_class.from_presentment_amount(purchase:, presentment_amount_cents: 1)
      expect(final).to be_present
      expect(final.canonical_gross_refund_cents).to eq(100 - 50 - second.canonical_gross_refund_cents)
      expect(final.presentment_refund.presentment_amount_cents).to eq(1)
    end

    it "returns nil when a prior refund has no presentment snapshot" do
      refund = build(:refund, purchase:, total_transaction_cents: 40, amount_cents: 40)
      purchase.refunds << refund

      expect(described_class.from_presentment_amount(purchase:, presentment_amount_cents: 54)).to be_nil
    end

    it "returns nil for a non-positive presentment amount" do
      expect(described_class.from_presentment_amount(purchase:, presentment_amount_cents: 0)).to be_nil
    end
  end

  # The Connect charge model decides how Stripe splits the money, not how much of the
  # buyer's presentment total is still refundable. Nothing in this service reads the
  # merchant account today; these specs are the tripwire for the day someone does.
  describe "charge-model independence" do
    let(:direct_charge_account) { create(:merchant_account_stripe_connect) }
    let(:destination_charge_account) { create(:merchant_account) }
    let(:platform_account) do
      MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
        create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
    end

    # The nil-account save fails `financial_transaction_validation`; skip validations
    # uniformly so every shape goes through the same path. The post-reload assertion is
    # the tripwire's own tripwire: a future callback that normalized `merchant_account`
    # on save would silently collapse these shapes into one and defuse both examples.
    def use_charge_model(merchant_account)
      purchase.merchant_account = merchant_account
      purchase.save!(validate: false)
      purchase.reload
      expect(purchase.merchant_account_id).to eq(merchant_account&.id)
    end

    def snapshot_for(merchant_account)
      use_charge_model(merchant_account)

      full = described_class.from_presentment_amount(purchase:, presentment_amount_cents: 135)
      partial = described_class.from_presentment_amount(purchase:, presentment_amount_cents: 54)
      tax_only = described_class.new(purchase:, canonical_gross_refund_cents: 100).tax_only_result

      {
        full: [full.canonical_gross_refund_cents, full.presentment_refund.json_data],
        partial: [partial.canonical_gross_refund_cents, partial.presentment_refund.json_data],
        tax_only: tax_only.json_data,
      }
    end

    it "derives identical refunds for direct, destination and platform charges" do
      expect(direct_charge_account.is_a_stripe_connect_account?).to eq(true)
      expect(destination_charge_account.is_a_stripe_connect_account?).to eq(false)
      expect(destination_charge_account.user).to be_present
      # The real platform shape is a Gumroad-managed row (user_id nil), not a nil
      # association — a guard on `is_managed_by_gumroad?` would escape the nil case.
      expect(platform_account.is_managed_by_gumroad?).to eq(true)

      direct = snapshot_for(direct_charge_account)
      destination = snapshot_for(destination_charge_account)
      platform = snapshot_for(platform_account)
      no_account = snapshot_for(nil)

      expect(direct).to eq(destination)
      expect(direct).to eq(platform)
      expect(direct).to eq(no_account)
      expect(direct[:full].first).to eq(100)
      expect(direct[:full].last[:presentment_amount_cents]).to eq(135)
      expect(direct[:partial].first).to eq(40)
      expect(direct[:tax_only][:presentment_gumroad_tax_cents]).to eq(20)
    end

    it "consumes presentment balance from prior refunds regardless of the charge model" do
      use_charge_model(direct_charge_account)
      refund = build(:refund, purchase:, total_transaction_cents: 40, amount_cents: 40)
      refund.presentment_currency = Currency::CAD
      refund.presentment_amount_cents = 54
      refund.presentment_price_cents = 54
      purchase.refunds << refund
      purchase.reload

      # 135 - 54 already refunded, so only 81 presentment cents remain on every shape.
      remaining_on = lambda do |merchant_account|
        use_charge_model(merchant_account)
        expect(described_class.from_presentment_amount(purchase:, presentment_amount_cents: 82)).to be_nil

        derived = described_class.from_presentment_amount(purchase:, presentment_amount_cents: 81)
        [derived.canonical_gross_refund_cents, derived.presentment_refund.json_data]
      end

      direct = remaining_on.call(direct_charge_account)

      # Value parity, not just boundary parity: a charge-model branch that only fires once
      # prior refunds exist would keep the 81/82 boundary and still derive a different amount.
      # The nil arm matters here too — a guard reading `merchant_account.nil?` on the
      # prior-refund path would escape an example that only varies the three real shapes.
      expect(remaining_on.call(destination_charge_account)).to eq(direct)
      expect(remaining_on.call(platform_account)).to eq(direct)
      expect(remaining_on.call(nil)).to eq(direct)
      expect(direct.first).to eq(60)
    end
  end

  describe "failed EUR refunds and re-refunds" do
    # Direct proof for the local-methods launch shape (iDEAL/Bancontact charge in
    # EUR): a refund the buyer's bank returned consumes NO refundable presentment
    # amount once reversed, and the subsequent re-refund derives the same full
    # canonical/presentment allocation a first refund would have.
    let(:eur_purchase) do
      build(:purchase,
            link: product,
            price_cents: 100,
            total_transaction_cents: 100,
            purchase_state: "successful").tap { _1.save!(validate: false) }
    end

    before do
      create(:purchase_presentment,
             purchase: eur_purchase,
             presentment_currency: Currency::EUR,
             presentment_price_cents: 90,
             presentment_tip_cents: 0,
             presentment_seller_tax_cents: 0,
             presentment_gumroad_tax_cents: 0,
             presentment_shipping_cents: 0,
             presentment_total_cents: 90,
             # The factory default (135) would exceed this small total and fail the
             # gumroad-amount capacity validation.
             presentment_gumroad_amount_cents: 9)
    end

    def record_failed_full_refund!(reversed:)
      refund = build(:refund, purchase: eur_purchase, total_transaction_cents: 100, amount_cents: 100,
                              processor_refund_id: "pyr_eur_failed", status: "failed")
      refund.presentment_currency = Currency::EUR
      refund.presentment_amount_cents = 90
      refund.presentment_price_cents = 90
      refund.balance_reversed_on_failure = true if reversed
      eur_purchase.refunds << refund
      refund
    end

    it "gives a reversed failed EUR refund no weight, so a full re-refund is derivable" do
      record_failed_full_refund!(reversed: true)

      # Full presentment amount is still refundable — the failed refund consumed none.
      derived = described_class.from_presentment_amount(purchase: eur_purchase.reload, presentment_amount_cents: 90)
      expect(derived).to be_present
      expect(derived.canonical_gross_refund_cents).to eq(100)
      expect(derived.presentment_refund.currency).to eq(Currency::EUR)
      expect(derived.presentment_refund.presentment_amount_cents).to eq(90)

      # And the forward direction (admin re-refund) computes the full snapshot too.
      result = described_class.new(purchase: eur_purchase, canonical_gross_refund_cents: 100).result
      expect(result.presentment_amount_cents).to eq(90)
      expect(result.currency).to eq(Currency::EUR)
    end

    it "keeps counting a failed EUR refund that was NOT reversed, blocking a double refund" do
      # Until the balance reversal runs, the seller is still debited — the presentment
      # amount must stay consumed or a second refund would move the money twice.
      record_failed_full_refund!(reversed: false)

      expect(described_class.from_presentment_amount(purchase: eur_purchase.reload, presentment_amount_cents: 90)).to be_nil
    end

    it "frees the presentment amount when the reversal runs through the real failure service" do
      # Same proof as above, but with balance_reversed_on_failure set by
      # Purchase::HandleFailedRefundService itself instead of by hand, so this
      # example breaks if the service stops reversing in a way the presentment
      # math depends on (e.g. no longer marking the refund reversed).
      refund = build(:refund, purchase: eur_purchase, total_transaction_cents: 100, amount_cents: 100,
                              gumroad_tax_cents: 0, creator_tax_cents: 0,
                              processor_refund_id: "pyr_eur_failed_service", status: "pending")
      refund.presentment_currency = Currency::EUR
      refund.presentment_amount_cents = 90
      refund.presentment_price_cents = 90
      eur_purchase.refunds << refund
      debit_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -100, net_cents: -100)
      BalanceTransaction.create!(
        user: eur_purchase.seller,
        merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
        refund:,
        issued_amount: debit_amount,
        holding_amount: debit_amount
      )
      eur_purchase.update!(stripe_refunded: true)

      Purchase::HandleFailedRefundService.new(refund:).perform

      expect(refund.reload.balance_reversed_on_failure).to eq(true)
      derived = described_class.from_presentment_amount(purchase: eur_purchase.reload, presentment_amount_cents: 90)
      expect(derived).to be_present
      expect(derived.canonical_gross_refund_cents).to eq(100)
      expect(derived.presentment_refund.currency).to eq(Currency::EUR)
      expect(derived.presentment_refund.presentment_amount_cents).to eq(90)
      expect(eur_purchase.stripe_refunded?).to eq(false)
    end
  end
end
