# frozen_string_literal: true

require "spec_helper"

describe Purchase::Reportable do
  let(:product) { create(:product) }
  let(:purchase) { create(:purchase, link: product) }

  describe "#price_cents_net_of_refunds" do
    it "returns the price" do
      expect(purchase.price_cents_net_of_refunds).to eq(100)
    end
  end

  context "when the purchase is chargedback" do
    before do
      purchase.update!(chargeback_date: Time.current)
    end

    it "returns 0" do
      expect(purchase.price_cents_net_of_refunds).to eq(0)
    end
  end

  context "when the purchase is fully refunded" do
    before do
      purchase.update!(stripe_refunded: true)
    end

    it "returns 0" do
      expect(purchase.price_cents_net_of_refunds).to eq(0)
    end
  end

  context "when the purchase is partially refunded" do
    before do
      purchase.update!(stripe_partially_refunded: true)
    end

    context "when the refunds don't have amounts" do
      before do
        create(:refund, purchase:, amount_cents: 0)
      end

      it "returns the price" do
        expect(purchase.price_cents_net_of_refunds).to eq(100)
      end
    end

    context "when refunds have amounts" do
      before do
        2.times do
          create(:refund, purchase:, amount_cents: 10)
        end
      end

      it "returns the price minus refunded amount" do
        expect(purchase.price_cents_net_of_refunds).to eq(80)
      end
    end

    context "with terminal-failure refunds" do
      # Reported net revenue must follow effective-refund semantics: a failed
      # refund whose balance debits were reversed never delivered money to the
      # buyer, so it must not reduce what we report as collected. A failed refund
      # that was NOT reversed still has the seller debited and keeps counting.
      let(:purchase) do
        create(:purchase, link: product, price_cents: 20_00, fee_cents: 2_00,
                          tax_cents: 60, gumroad_tax_cents: 1_00,
                          total_transaction_cents: 21_00, stripe_partially_refunded: true)
      end

      def create_partial_refund(status:, reversed: false)
        refund = create(:refund,
                        purchase:,
                        amount_cents: 5_00,
                        fee_cents: 50,
                        creator_tax_cents: 15,
                        gumroad_tax_cents: 25,
                        total_transaction_cents: 5_25,
                        status:)
        if reversed
          refund.balance_reversed_on_failure = true
          refund.save!
        end
        refund
      end

      # The purchase model recalculates fee/tax cents on save, so expectations are
      # relative to the persisted purchase attributes rather than literal values.
      it "keeps subtracting a failed refund until its balance debits are reversed" do
        create_partial_refund(status: "failed")

        expect(purchase.price_cents_net_of_refunds).to eq(purchase.price_cents - 5_00)
        expect(purchase.fee_cents_net_of_refunds).to eq(purchase.fee_cents - 50)
        expect(purchase.tax_cents_net_of_refunds).to eq(purchase.tax_cents - 15)
        expect(purchase.gumroad_tax_cents_net_of_refunds).to eq(purchase.gumroad_tax_cents - 25)
        expect(purchase.total_cents_net_of_refunds).to eq(purchase.total_transaction_cents - 5_25)
      end

      it "subtracts only the surviving refund once the failed refund is reversed" do
        create_partial_refund(status: "succeeded")
        create_partial_refund(status: "failed", reversed: true)

        expect(purchase.price_cents_net_of_refunds).to eq(purchase.price_cents - 5_00)
        expect(purchase.fee_cents_net_of_refunds).to eq(purchase.fee_cents - 50)
        expect(purchase.tax_cents_net_of_refunds).to eq(purchase.tax_cents - 15)
        expect(purchase.gumroad_tax_cents_net_of_refunds).to eq(purchase.gumroad_tax_cents - 25)
        expect(purchase.total_cents_net_of_refunds).to eq(purchase.total_transaction_cents - 5_25)
      end
    end
  end

  describe "#price_cents_for_tax_reporting" do
    let(:cutover) { Purchase::Reportable::REFUND_REPORTING_CUTOVER }

    context "for a purchase created before the refund reporting cutover" do
      let(:purchase) do
        create(:purchase, link: product).tap { |p| p.update_column(:created_at, cutover.beginning_of_day - 30.days) }
      end

      it "returns the price when nothing was refunded" do
        expect(purchase.price_cents_for_tax_reporting).to eq(100)
      end

      it "nets only pre-cutover refunds, leaving post-cutover refunds to the refund leg" do
        create(:refund, purchase:, amount_cents: 10).update_column(:created_at, cutover.beginning_of_day - 10.days)
        create(:refund, purchase:, amount_cents: 25).update_column(:created_at, cutover.beginning_of_day + 10.days)
        purchase.update!(stripe_partially_refunded: true)

        # Only the pre-cutover 10 is netted; the post-cutover 25 is reported as its own
        # refund row in the period it happened, so netting it here would double-count it.
        expect(purchase.price_cents_for_tax_reporting).to eq(90)
      end

      it "returns 0 when fully refunded pre-cutover" do
        create(:refund, purchase:, amount_cents: 100).update_column(:created_at, cutover.beginning_of_day - 10.days)
        purchase.update!(stripe_refunded: true)

        expect(purchase.price_cents_for_tax_reporting).to eq(0)
      end
    end

    context "for a purchase created on/after the refund reporting cutover" do
      let(:purchase) do
        create(:purchase, link: product).tap { |p| p.update_column(:created_at, cutover.beginning_of_day + 1.day) }
      end

      it "returns the gross price even when refunded" do
        create(:refund, purchase:, amount_cents: 100).update_column(:created_at, cutover.beginning_of_day + 5.days)
        purchase.update!(stripe_refunded: true)

        # Post-cutover purchases report gross; their refund rows (in the refund's own
        # period) are what offset them.
        expect(purchase.price_cents_for_tax_reporting).to eq(100)
      end
    end

    context "when the purchase is chargedback and not reversed" do
      let(:purchase) do
        create(:purchase, link: product).tap { |p| p.update_column(:created_at, cutover.beginning_of_day + 1.day) }
      end

      it "returns 0 (chargeback attribution is unchanged by the refund cutover)" do
        purchase.update!(chargeback_date: Time.current)

        expect(purchase.price_cents_for_tax_reporting).to eq(0)
      end
    end
  end
end

describe "Purchase.not_fully_refunded_for_tax_reporting" do
  let(:cutover) { Purchase::Reportable::REFUND_REPORTING_CUTOVER }

  def purchase_created_at(time)
    create(:purchase).tap { |p| p.update_column(:created_at, time) }
  end

  it "keeps a pre-cutover sale that was fully refunded on/after the cutover" do
    # The Greptile P1 scenario: a June sale fully refunded in August. The refund gets its own
    # negative row in August, so the June sale row must stay — dropping it would understate
    # the combined periods by the sale amount.
    purchase = purchase_created_at(cutover.beginning_of_day - 30.days)
    create(:refund, purchase:, amount_cents: 100).update_column(:created_at, cutover.beginning_of_day + 10.days)
    purchase.update!(stripe_refunded: true)

    expect(Purchase.not_fully_refunded_for_tax_reporting).to include(purchase)
  end

  it "still drops a pre-cutover sale fully refunded before the cutover" do
    purchase = purchase_created_at(cutover.beginning_of_day - 30.days)
    create(:refund, purchase:, amount_cents: 100).update_column(:created_at, cutover.beginning_of_day - 10.days)
    purchase.update!(stripe_refunded: true)

    expect(Purchase.not_fully_refunded_for_tax_reporting).not_to include(purchase)
  end

  it "still drops a pre-cutover fully-refunded sale whose only post-cutover refund was a reversed failure" do
    # A reversed-failure refund returned no money and gets no refund row (Refund.effective
    # excludes it), so it can't rescue the sale row.
    purchase = purchase_created_at(cutover.beginning_of_day - 30.days)
    refund = create(:refund, purchase:, amount_cents: 100, status: "failed")
    refund.balance_reversed_on_failure = true
    refund.balance_reversed_on_failure_at = Time.current.utc.iso8601
    refund.save!
    refund.update_column(:created_at, cutover.beginning_of_day + 10.days)
    purchase.update!(stripe_refunded: true)

    expect(Purchase.not_fully_refunded_for_tax_reporting).not_to include(purchase)
  end

  it "keeps a pre-cutover fully-refunded sale whose post-cutover refund failed but was not reversed" do
    # A failed-but-not-reversed refund still counts (Refund.effective keeps it) and gets its own
    # refund row, so the sale row must stay for that row to subtract from.
    purchase = purchase_created_at(cutover.beginning_of_day - 30.days)
    create(:refund, purchase:, amount_cents: 100, status: "failed").update_column(:created_at, cutover.beginning_of_day + 10.days)
    purchase.update!(stripe_refunded: true)

    expect(Purchase.not_fully_refunded_for_tax_reporting).to include(purchase)
  end

  it "keeps post-cutover sales even when fully refunded" do
    purchase = purchase_created_at(cutover.beginning_of_day + 1.day)
    create(:refund, purchase:, amount_cents: 100).update_column(:created_at, cutover.beginning_of_day + 5.days)
    purchase.update!(stripe_refunded: true)

    expect(Purchase.not_fully_refunded_for_tax_reporting).to include(purchase)
  end
end

describe "Refund.for_tax_period_reporting" do
  let(:cutover) { Purchase::Reportable::REFUND_REPORTING_CUTOVER }
  let(:purchase) do
    create(:purchase).tap { |p| p.update_column(:created_at, cutover.beginning_of_day - 30.days) }
  end

  it "includes effective post-cutover refunds in the window and excludes reversed failures" do
    pre_cutover = create(:refund, purchase:, amount_cents: 10).tap { |r| r.update_column(:created_at, cutover.beginning_of_day - 1.day) }
    in_window = create(:refund, purchase:, amount_cents: 10).tap { |r| r.update_column(:created_at, cutover.beginning_of_day + 1.day) }
    # Failed but not reversed: the money still left us, so Refund.effective keeps it.
    failed_not_reversed = create(:refund, purchase:, amount_cents: 10, status: "failed").tap { |r| r.update_column(:created_at, cutover.beginning_of_day + 2.days) }
    # Failed and reversed: the money came back and the buyer never received it, so it is excluded.
    reversed_failure = create(:refund, purchase:, amount_cents: 10, status: "failed")
    reversed_failure.balance_reversed_on_failure = true
    reversed_failure.balance_reversed_on_failure_at = Time.current.utc.iso8601
    reversed_failure.save!
    reversed_failure.update_column(:created_at, cutover.beginning_of_day + 3.days)
    after_window = create(:refund, purchase:, amount_cents: 10).tap { |r| r.update_column(:created_at, cutover.beginning_of_day + 40.days) }

    result = Refund.for_tax_period_reporting(cutover.beginning_of_day, cutover.beginning_of_day + 30.days)

    expect(result).to include(in_window, failed_not_reversed)
    expect(result).not_to include(pre_cutover, reversed_failure, after_window)
  end
end

describe "chargeback event-date reporting" do
  let(:cutover) { Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER.beginning_of_day }

  describe "#chargeback_event_dated_for_tax_reporting?" do
    let(:purchase) { create(:purchase) }

    it "is false when there is no chargeback" do
      expect(purchase.chargeback_event_dated_for_tax_reporting?).to eq(false)
    end

    it "is false for a pre-cutover chargeback (kept as filed)" do
      purchase.update!(chargeback_date: cutover - 1.day)

      expect(purchase.chargeback_event_dated_for_tax_reporting?).to eq(false)
    end

    it "is true for a post-cutover chargeback that was not reversed" do
      purchase.update!(chargeback_date: cutover + 1.day)

      expect(purchase.chargeback_event_dated_for_tax_reporting?).to eq(true)
    end

    it "is false for a reversed post-cutover chargeback with no dispute row dating the win" do
      # Without a real won_at the re-add leg could never be emitted, so the debit leg must
      # not be either — the purchase keeps the legacy treatment.
      purchase.update!(chargeback_date: cutover + 1.day, chargeback_reversed: true)

      expect(purchase.chargeback_event_dated_for_tax_reporting?).to eq(false)
    end

    it "is true for a reversed post-cutover chargeback whose dispute row records won_at" do
      purchase.update!(chargeback_date: cutover + 1.day, chargeback_reversed: true)
      create(:dispute, purchase:, state: "won", won_at: cutover + 10.days)

      expect(purchase.chargeback_event_dated_for_tax_reporting?).to eq(true)
    end
  end

  describe "#chargeback_reversal_reporting_date" do
    it "takes won_at from a dispute on the purchase's charge for multi-purchase carts" do
      purchase = create(:purchase, chargeback_date: cutover + 1.day, chargeback_reversed: true)
      charge = create(:charge)
      charge.purchases << purchase
      won_at = cutover + 12.days
      create(:dispute_on_charge, charge:, state: "won", won_at:)

      expect(purchase.chargeback_reversal_reporting_date).to eq(won_at)
    end

    it "is nil when the chargeback was not reversed or no dispute records a win" do
      purchase = create(:purchase, chargeback_date: cutover + 1.day)
      expect(purchase.chargeback_reversal_reporting_date).to be_nil

      purchase.update!(chargeback_reversed: true)
      create(:dispute, purchase:, state: "lost", lost_at: cutover + 5.days)
      expect(purchase.chargeback_reversal_reporting_date).to be_nil
    end
  end

  describe "#price_cents_for_chargeback_reporting" do
    it "nets effective refunds that predate the chargeback out of the clawed-back amount" do
      purchase = create(:purchase, price_cents: 100_00, chargeback_date: cutover + 30.days)
      create(:refund, purchase:, amount_cents: 40_00).update_column(:created_at, cutover + 1.day)
      # A reversed-failure refund returned no money, so it must not shrink the clawback.
      reversed = create(:refund, purchase:, amount_cents: 30_00, status: "failed")
      reversed.balance_reversed_on_failure = true
      reversed.save!
      reversed.update_column(:created_at, cutover + 1.day)

      expect(purchase.price_cents_for_chargeback_reporting).to eq(purchase.price_cents - 40_00)
    end

    it "ignores a refund issued after a dispute win, keeping already-filed legs stable" do
      # Refunds are blocked while a chargeback stands, but a won dispute makes the purchase
      # refundable again. Such a refund must not shrink the debit/re-add legs already filed
      # for the chargeback and won periods — it is relieved by the refund leg of its own
      # period instead. Netting it here would make regenerated historical reports disagree
      # with what was filed.
      purchase = create(:purchase, price_cents: 100_00, chargeback_date: cutover + 1.day, chargeback_reversed: true)
      create(:dispute, purchase:, state: "won", won_at: cutover + 10.days)
      create(:refund, purchase:, amount_cents: 40_00).update_column(:created_at, cutover + 20.days)

      expect(purchase.price_cents_for_chargeback_reporting).to eq(purchase.price_cents)
    end
  end

  describe "#price_cents_for_tax_reporting with chargebacks" do
    it "keeps reporting the sale of an event-dated chargeback and zeroes a legacy one" do
      event_dated = create(:purchase, chargeback_date: cutover + 1.day)
      legacy = create(:purchase, chargeback_date: cutover - 1.day)

      expect(event_dated.price_cents_for_tax_reporting).to eq(event_dated.price_cents)
      expect(legacy.price_cents_for_tax_reporting).to eq(0)
    end
  end

  describe "Purchase.not_chargedback_for_tax_reporting" do
    it "keeps event-dated and reversed chargebacks, drops legacy lost ones and undated reversals" do
      clean = create(:purchase)
      event_dated = create(:purchase, chargeback_date: cutover + 1.day)
      legacy_lost = create(:purchase, chargeback_date: cutover - 1.day)
      legacy_won = create(:purchase, chargeback_date: cutover - 1.day, chargeback_reversed: true)
      undated_reversal = create(:purchase, chargeback_date: cutover + 1.day, chargeback_reversed: true)
      dated_reversal = create(:purchase, chargeback_date: cutover + 1.day, chargeback_reversed: true)
      create(:dispute, purchase: dated_reversal, state: "won", won_at: cutover + 10.days)

      result = Purchase.not_chargedback_for_tax_reporting

      # The undated reversal is still kept: reversed chargebacks always pass the sales-leg
      # gate (their sale belongs in the purchase period under both treatments).
      expect(result).to include(clean, event_dated, legacy_won, undated_reversal, dated_reversal)
      expect(result).not_to include(legacy_lost)
    end
  end

  describe "Purchase.chargebacks_for_tax_period_reporting" do
    it "selects event-dated chargebacks whose event date falls in the window" do
      # In production a chargeback_date is always mirrored by a Dispute row's event_created_at
      # (both are set from the same processor event when the dispute is formalized), and the
      # scope now resolves the window through disputes, so give each charged-back purchase its
      # matching dispute — directly, or on its Charge for a multi-purchase cart.
      in_window = create(:purchase, chargeback_date: cutover + 5.days)
      create(:dispute, purchase: in_window, event_created_at: cutover + 5.days)

      charge_in_window = create(:purchase, chargeback_date: cutover + 6.days)
      charge = create(:charge)
      charge.purchases << charge_in_window
      create(:dispute_on_charge, charge:, event_created_at: cutover + 6.days)

      after_window = create(:purchase, chargeback_date: cutover + 40.days)
      create(:dispute, purchase: after_window, event_created_at: cutover + 40.days)

      legacy = create(:purchase, chargeback_date: cutover - 1.day)
      create(:dispute, purchase: legacy, event_created_at: cutover - 1.day)

      undated_reversal = create(:purchase, chargeback_date: cutover + 5.days, chargeback_reversed: true)
      create(:dispute, purchase: undated_reversal, event_created_at: cutover + 5.days)

      dated_reversal = create(:purchase, chargeback_date: cutover + 5.days, chargeback_reversed: true)
      create(:dispute, purchase: dated_reversal, state: "won", event_created_at: cutover + 5.days, won_at: cutover + 60.days)

      # A chargeback_date carried without any Dispute row belongs only to the $0 gift/bundle
      # child purchases, which every caller already excludes; the disputes-driven scope leaves
      # it out (this is what the old chargeback_date-only scan would have wrongly included).
      dispute_less = create(:purchase, chargeback_date: cutover + 5.days)

      result = Purchase.chargebacks_for_tax_period_reporting(cutover, cutover + 30.days)

      # The undated reversal emits no debit leg — with no real won_at its re-add leg could
      # never balance it, so it keeps the legacy treatment entirely.
      expect(result).to include(in_window, charge_in_window, dated_reversal)
      expect(result).not_to include(after_window, legacy, undated_reversal, dispute_less)
    end
  end

  describe "Purchase.chargeback_reversals_for_tax_period_reporting" do
    it "selects reversed post-cutover chargebacks whose dispute was won in the window" do
      won_in_window = create(:purchase, chargeback_date: cutover + 1.day, chargeback_reversed: true)
      create(:dispute, purchase: won_in_window, state: "won", won_at: cutover + 10.days)

      won_later = create(:purchase, chargeback_date: cutover + 1.day, chargeback_reversed: true)
      create(:dispute, purchase: won_later, state: "won", won_at: cutover + 60.days)

      legacy_won = create(:purchase, chargeback_date: cutover - 1.day, chargeback_reversed: true)
      create(:dispute, purchase: legacy_won, state: "won", won_at: cutover + 10.days)

      undated_reversal = create(:purchase, chargeback_date: cutover + 1.day, chargeback_reversed: true)

      charge_won = create(:purchase, chargeback_date: cutover + 1.day, chargeback_reversed: true)
      charge = create(:charge)
      charge.purchases << charge_won
      create(:dispute_on_charge, charge:, state: "won", won_at: cutover + 12.days)

      result = Purchase.chargeback_reversals_for_tax_period_reporting(cutover, cutover + 30.days)

      expect(result).to include(won_in_window, charge_won)
      expect(result).not_to include(won_later, legacy_won, undated_reversal)
    end
  end
end
