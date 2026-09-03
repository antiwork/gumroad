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
        expect(described_class.chargeback_rate_reserve_cents(199_084)).to eq(49_771)
      end
    end

    describe ".is_user_payable" do
      let(:date) { Date.today - 1 }

      it "lets a chargeback-volume hold through at 75 percent instead of skipping" do
        seller = payable_stripe_seller
        unpaid_balance(seller, cents: 400_00, on: date - 2)
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

      it "skips when 75 percent of the unpaid balance is below the minimum" do
        seller = payable_stripe_seller
        unpaid_balance(seller, cents: 120_00, on: date - 2)
        pause_for_chargeback_rate!(seller)

        expect(described_class.is_user_payable(seller, date, processor_type: PayoutProcessorType::STRIPE)).to eq(false)
      end
    end

    describe ".apply_chargeback_rate_reserve" do
      it "keeps the oldest rows whose sum is at most 75 percent and does not split a row" do
        seller = create(:user)
        pause_for_chargeback_rate!(seller)
        older = unpaid_balance(seller, cents: 40_00, on: Date.today - 10)
        middle = unpaid_balance(seller, cents: 30_00, on: Date.today - 5)
        newer = unpaid_balance(seller, cents: 30_00, on: Date.today - 2)

        selected = described_class.send(:apply_chargeback_rate_reserve, seller, [newer, older, middle])

        expect(selected).to eq([older, middle])
        expect(selected.sum(&:amount_cents)).to eq(70_00)
      end

      it "pays nothing this cycle when the oldest row is larger than the 75 percent cap" do
        seller = create(:user)
        pause_for_chargeback_rate!(seller)
        fat = unpaid_balance(seller, cents: 90_00, on: Date.today - 3)
        thin = unpaid_balance(seller, cents: 10_00, on: Date.today - 2)

        selected = described_class.send(:apply_chargeback_rate_reserve, seller, [fat, thin])

        expect(selected).to eq([])
      end

      it "does not filter balances when the reserve is not active" do
        seller = create(:user)
        balances = [unpaid_balance(seller, cents: 40_00, on: Date.today - 2)]

        expect(described_class.send(:apply_chargeback_rate_reserve, seller, balances)).to eq(balances)
      end
    end
  end
end
