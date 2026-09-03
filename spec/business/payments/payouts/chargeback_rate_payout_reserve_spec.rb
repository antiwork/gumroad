# frozen_string_literal: true

require "spec_helper"

describe "chargeback-rate payout reserve" do
  def pause_for_chargeback_rate!(user)
    user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
    user.comments.create!(
      content: "Payouts automatically paused due to chargeback rate (4.0%) exceeding #{User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS}% volume over the last #{User::PAYOUT_CHARGEBACK_RATE_WINDOW.inspect}.",
      comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
      author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:high_chargeback_rate]
    )
  end

  def payable_stripe_seller
    seller = create(:user_with_compliance_info)
    create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_reserve_#{SecureRandom.hex(4)}")
    create(:ach_account, user: seller, stripe_bank_account_id: "ba_bankaccountid")
    seller.update!(user_risk_state: "compliant")
    seller
  end

  def unpaid_balance(user, cents:, on: Date.today - 3)
    merchant_account = user.merchant_accounts.first || create(:merchant_account, user: user)
    create(:balance, user:, merchant_account:, date: on, amount_cents: cents, holding_amount_cents: cents)
  end

  def claim_balance!(row, payment_amount_cents: row.amount_cents, currency: nil, payment_created_at: Time.current)
    row.mark_processing!
    row.mark_paid!
    attrs = { user: row.user, amount_cents: payment_amount_cents, created_at: payment_created_at }
    attrs[:currency] = currency if currency
    payment = create(:payment_completed, **attrs)
    payment.balances << row
    row
  end

  describe User::Risk, "#chargeback_rate_payout_reserve_active?" do
    let(:seller) { create(:user) }

    it "is true only for the automatic chargeback-volume hold" do
      expect(seller.chargeback_rate_payout_reserve_active?).to eq(false)

      pause_for_chargeback_rate!(seller)
      expect(seller.chargeback_rate_payout_reserve_active?).to eq(true)
    end

    it "stays off for a system pause that is not the chargeback-volume hold" do
      seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
      seller.comments.create!(
        content: "paused after repeated failures",
        comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
        author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:repeated_failed_payouts]
      )

      expect(seller.chargeback_rate_payout_reserve_active?).to eq(false)
    end

    it "is off when the seller paused payouts themselves on top of the hold" do
      pause_for_chargeback_rate!(seller)
      seller.update!(payouts_paused_by_user: true)

      expect(seller.chargeback_rate_payout_reserve_active?).to eq(false)
    end

    it "is off when the kill switch is on" do
      pause_for_chargeback_rate!(seller)
      allow(Feature).to receive(:active?).and_call_original
      allow(Feature).to receive(:active?).with(:disable_chargeback_rate_payout_reserve).and_return(true)

      expect(seller.chargeback_rate_payout_reserve_active?).to eq(false)
    end
  end

  describe Payouts do
    describe ".chargeback_rate_reserve_cents" do
      it "holds 25 percent, rounding up so a payout cannot send more than 75 percent" do
        expect(described_class.chargeback_rate_reserve_cents(0)).to eq(0)
        expect(described_class.chargeback_rate_reserve_cents(100_00)).to eq(25_00)
        # 100_01 * 25% = 2500.25; ceil is 2501. floor/to_i/round all give 2500.
        expect(described_class.chargeback_rate_reserve_cents(100_01)).to eq(25_01)
      end
    end

    describe ".is_user_payable" do
      let(:date) { Date.today - 1 }

      it "lets a chargeback-volume hold through at 75 percent instead of skipping" do
        seller = payable_stripe_seller
        # Four $100 rows so a prefix fits under the $300 cap; a single $400 row cannot.
        4.times { |i| unpaid_balance(seller, cents: 100_00, on: date - 5 + i) }
        pause_for_chargeback_rate!(seller)

        expect(described_class.is_user_payable(seller, date, processor_type: PayoutProcessorType::STRIPE)).to eq(true)
      end

      it "still skips a generic system pause that is not the chargeback-volume hold" do
        seller = payable_stripe_seller
        unpaid_balance(seller, cents: 400_00, on: date - 2)
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)

        expect(described_class.is_user_payable(seller, date, processor_type: PayoutProcessorType::STRIPE, add_comment: true)).to eq(false)
        expect(seller.comments.with_type_payout_note.last.content).to include("paused by the system")
      end

      it "still skips when the seller paused payouts themselves on top of the chargeback-volume hold" do
        seller = payable_stripe_seller
        4.times { |i| unpaid_balance(seller, cents: 100_00, on: date - 5 + i) }
        pause_for_chargeback_rate!(seller)
        seller.update!(payouts_paused_by_user: true)

        expect(described_class.is_user_payable(seller, date, processor_type: PayoutProcessorType::STRIPE)).to eq(false)
      end

      it "still skips instant payouts under the chargeback-volume hold" do
        seller = payable_stripe_seller
        4.times { |i| unpaid_balance(seller, cents: 100_00, on: date - 5 + i) }
        pause_for_chargeback_rate!(seller)

        expect(
          described_class.is_user_payable(
            seller, date, processor_type: PayoutProcessorType::STRIPE, payout_type: Payouts::PAYOUT_TYPE_INSTANT
          )
        ).to eq(false)
      end

      it "skips when no whole unpaid row fits under the 75 percent cap" do
        seller = payable_stripe_seller
        unpaid_balance(seller, cents: 400_00, on: date - 2)
        pause_for_chargeback_rate!(seller)

        expect(described_class.is_user_payable(seller, date, processor_type: PayoutProcessorType::STRIPE)).to eq(false)
      end

      it "skips when 75 percent of the unpaid balance is below the minimum" do
        seller = payable_stripe_seller
        unpaid_balance(seller, cents: 120_00, on: date - 2)
        pause_for_chargeback_rate!(seller)

        expect(described_class.is_user_payable(seller, date, processor_type: PayoutProcessorType::STRIPE)).to eq(false)
      end
    end

    describe ".chargeback_rate_reserve_cents_for_run" do
      it "anchors the 25 percent on unpaid plus what was already paid under the hold, so repeat runs cannot drain the reserve" do
        seller = create(:user)
        pause_for_chargeback_rate!(seller)
        claim_balance!(unpaid_balance(seller, cents: 75_00, on: Date.today - 8))

        # $100 originally held: $75 paid on the first run, $25 remaining. The reserve is still
        # 25% of $100, clamped to the $25 that is left — nothing more releases.
        expect(described_class.chargeback_rate_reserve_cents_for_run(seller, 25_00)).to eq(25_00)
      end

      it "counts claimed USD balance cents, not a payout-currency amount" do
        seller = create(:user)
        pause_for_chargeback_rate!(seller)
        claim_balance!(unpaid_balance(seller, cents: 75_00, on: Date.today - 8), payment_amount_cents: 6_375_00, currency: Currency::INR)

        # Remaining unpaid is large so counting a local-currency payout amount would
        # clamp the reserve to the whole pot instead of 25% of (paid USD + unpaid).
        expect(described_class.chargeback_rate_reserve_cents_for_run(seller, 400_00)).to eq(118_75)
      end

      it "counts claimed USD balance cents after the hold, not a fee-net payout amount" do
        seller = create(:user)
        pause_for_chargeback_rate!(seller)
        claim_balance!(unpaid_balance(seller, cents: 75_00, on: Date.today - 8), payment_amount_cents: 73_17)

        expect(described_class.chargeback_rate_reserve_cents_for_run(seller, 25_00)).to eq(25_00)
      end

      it "ignores balances claimed before the hold started" do
        seller = create(:user)
        claim_balance!(unpaid_balance(seller, cents: 500_00, on: Date.today - 10), payment_created_at: 2.days.ago)
        pause_for_chargeback_rate!(seller)

        # Unanchored would count the $500 too: min(25% of $600, $100) = $100.
        expect(described_class.chargeback_rate_reserve_cents_for_run(seller, 100_00)).to eq(25_00)
      end

      it "ignores a pre-hold processing payout that mark_paid after the hold starts" do
        seller = create(:user)
        row = unpaid_balance(seller, cents: 500_00, on: Date.today - 10)
        row.mark_processing!
        payment = create(:payment_completed, user: seller, amount_cents: 500_00, created_at: 2.days.ago)
        payment.balances << row
        pause_for_chargeback_rate!(seller)
        row.mark_paid!

        expect(described_class.chargeback_rate_reserve_cents_for_run(seller, 100_00)).to eq(25_00)
      end

      it "counts in-flight processing balances before a Payment row exists" do
        seller = create(:user)
        pause_for_chargeback_rate!(seller)
        unpaid_balance(seller, cents: 75_00, on: Date.today - 8).mark_processing!

        expect(described_class.chargeback_rate_reserve_cents_for_run(seller, 25_00)).to eq(25_00)
      end

      it "counts balances attached to a Payment that is still creating" do
        seller = create(:user)
        pause_for_chargeback_rate!(seller)
        row = unpaid_balance(seller, cents: 75_00, on: Date.today - 8)
        row.mark_processing!
        payment = create(:payment, user: seller, state: Payment::CREATING, created_at: Time.current)
        payment.balances << row

        expect(described_class.chargeback_rate_reserve_cents_for_run(seller, 25_00)).to eq(25_00)
      end

      it "counts processing balances attached to processing or unclaimed payments" do
        seller = create(:user)
        pause_for_chargeback_rate!(seller)
        processing_row = unpaid_balance(seller, cents: 50_00, on: Date.today - 8)
        unclaimed_row = unpaid_balance(seller, cents: 25_00, on: Date.today - 7)
        processing_row.mark_processing!
        unclaimed_row.mark_processing!
        create(:payment, user: seller, state: Payment::PROCESSING, created_at: Time.current).balances << processing_row
        create(:payment, user: seller, state: Payment::UNCLAIMED, created_at: Time.current).balances << unclaimed_row

        expect(described_class.chargeback_rate_reserve_cents_for_run(seller, 25_00)).to eq(25_00)
      end
    end

    describe ".apply_chargeback_rate_reserve" do
      it "keeps the oldest rows whose sum is at most 75 percent and does not split a row" do
        seller = create(:user)
        pause_for_chargeback_rate!(seller)
        older = unpaid_balance(seller, cents: 40_00, on: Date.today - 10)
        middle = unpaid_balance(seller, cents: 30_00, on: Date.today - 5)
        newer = unpaid_balance(seller, cents: 30_00, on: Date.today - 2)

        selected = described_class.send(:apply_chargeback_rate_reserve, seller, [newer, older, middle], minimum_cents: 0)

        expect(selected).to eq([older, middle])
        expect(selected.sum(&:amount_cents)).to eq(70_00)
      end

      it "pays nothing this cycle when the oldest row is larger than the 75 percent cap" do
        seller = create(:user)
        pause_for_chargeback_rate!(seller)
        fat = unpaid_balance(seller, cents: 90_00, on: Date.today - 3)
        thin = unpaid_balance(seller, cents: 10_00, on: Date.today - 2)

        selected = described_class.send(:apply_chargeback_rate_reserve, seller, [fat, thin], minimum_cents: 0)

        expect(selected).to eq([])
      end

      it "pays nothing when whole-row selection stops below the payout minimum" do
        seller = create(:user)
        pause_for_chargeback_rate!(seller)
        # Aggregate $200 clears the $100 minimum after the reserve ($150 cap), but only the
        # $90 row fits under the cap once the $110 row cannot be split — $90 < $100 minimum.
        small = unpaid_balance(seller, cents: 90_00, on: Date.today - 5)
        big = unpaid_balance(seller, cents: 110_00, on: Date.today - 2)

        selected = described_class.send(:apply_chargeback_rate_reserve, seller, [small, big], minimum_cents: 100_00)

        expect(selected).to eq([])
      end

      it "releases nothing further on a later run once 75 percent has already been paid under the hold" do
        seller = create(:user)
        pause_for_chargeback_rate!(seller)
        claim_balance!(unpaid_balance(seller, cents: 75_00, on: Date.today - 8))
        # Two rows, so a reserve recomputed from the $25 remainder (cap $18.75) would still
        # select the $15 row — only the anchored reserve holds the whole remainder back.
        remainder_old = unpaid_balance(seller, cents: 15_00, on: Date.today - 3)
        remainder_new = unpaid_balance(seller, cents: 10_00, on: Date.today - 2)

        selected = described_class.send(:apply_chargeback_rate_reserve, seller, [remainder_old, remainder_new], minimum_cents: 0)

        expect(selected).to eq([])
      end

      it "does not filter balances when the reserve is not active" do
        seller = create(:user)
        balances = [unpaid_balance(seller, cents: 40_00, on: Date.today - 2)]

        expect(described_class.send(:apply_chargeback_rate_reserve, seller, balances, minimum_cents: 100_00)).to eq(balances)
      end

      it "uses the full unpaid pot as the cap even when selecting a processor-filtered slice" do
        seller = create(:user)
        pause_for_chargeback_rate!(seller)
        stripe_row = unpaid_balance(seller, cents: 100_00, on: Date.today - 4)
        unpaid_balance(seller, cents: 100_00, on: Date.today - 3)

        # Slice is only the first rail's $100. Base is $200, so cap is $150 and the
        # whole $100 row fits — a slice-only base would cap at $75 and skip it.
        selected = described_class.send(
          :apply_chargeback_rate_reserve,
          seller,
          [stripe_row],
          minimum_cents: 0,
          unpaid_cents: 200_00
        )

        expect(selected).to eq([stripe_row])
      end
    end

    describe ".create_payment under the hold" do
      let(:date) { Date.today - 1 }

      def stub_stripe_prepare!
        allow(StripePayoutProcessor).to receive(:prepare_payment_and_set_amount) do |payment, balances|
          payment.currency = Currency::USD
          payment.amount_cents = balances.sum(&:holding_amount_cents)
          []
        end
      end

      it "claims 75 percent of unpaid Stripe rows on the payment path" do
        seller = payable_stripe_seller
        4.times { |i| unpaid_balance(seller, cents: 100_00, on: date - 5 + i) }
        pause_for_chargeback_rate!(seller)
        allow(StripePayoutProcessor).to receive(:is_balance_payable).and_return(true)
        stub_stripe_prepare!

        payment, payment_errors = described_class.create_payment(date.to_s, PayoutProcessorType::STRIPE, seller)

        expect(payment_errors).to eq([])
        expect(payment.balances.sum(&:amount_cents)).to eq(300_00)
        expect(seller.balances.unpaid.sum(:amount_cents)).to eq(100_00)
      end

      it "selects a processor slice using the full unpaid pot as the cap" do
        seller = payable_stripe_seller
        stripe_row = unpaid_balance(seller, cents: 100_00, on: date - 4)
        other_row = unpaid_balance(seller, cents: 100_00, on: date - 3)
        pause_for_chargeback_rate!(seller)
        allow(StripePayoutProcessor).to receive(:is_balance_payable) { |balance| balance.id == stripe_row.id }
        stub_stripe_prepare!

        payment, payment_errors = described_class.create_payment(date.to_s, PayoutProcessorType::STRIPE, seller)

        expect(payment_errors).to eq([])
        expect(payment.balances.map(&:id)).to eq([stripe_row.id])
        expect(other_row.reload).to be_unpaid
      end

      it "does not let a newer processor slice leapfrog an older row on another rail" do
        seller = payable_stripe_seller
        older_other_rail = unpaid_balance(seller, cents: 1_000_00, on: date - 5)
        newer_stripe_row = unpaid_balance(seller, cents: 300_00, on: date - 4)
        pause_for_chargeback_rate!(seller)
        allow(StripePayoutProcessor).to receive(:is_balance_payable) { |balance| balance.id == newer_stripe_row.id }
        allow(StripePayoutProcessor).to receive(:filter_aggregate_payable_balances) { |_user, balances| balances }
        allow(PaypalPayoutProcessor).to receive(:is_balance_payable) { |balance| balance.id == older_other_rail.id }

        payment = described_class.create_payment(date.to_s, PayoutProcessorType::STRIPE, seller)

        expect(payment).to be_nil
        expect(older_other_rail.reload).to be_unpaid
        expect(newer_stripe_row.reload).to be_unpaid
      end
    end
  end
end
