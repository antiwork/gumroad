# frozen_string_literal: true

require "spec_helper"

describe Onetime::RestoreStrandedPaypalReversalBalances do
  let(:seller) { create(:user) }
  let(:merchant_account) { create(:merchant_account_paypal, user: seller) }

  def build_balance(state: "processing", **overrides)
    create(:balance, user: seller, merchant_account:, state:, **overrides)
  end

  def build_payment(factory, balances:)
    payment = create(factory, user: seller)
    payment.balances << balances
    payment
  end

  describe ".process" do
    it "restores balances stranded in processing by a reversed PayPal payout" do
      balance = build_balance
      build_payment(:payment_reversed, balances: [balance])

      result = described_class.process(dry_run: false)

      expect(balance.reload.state).to eq("unpaid")
      expect(result[:balances_restored]).to eq(1)
    end

    it "restores balances stranded by a returned PayPal payout" do
      balance = build_balance
      build_payment(:payment_returned, balances: [balance])

      result = described_class.process(dry_run: false)

      expect(balance.reload.state).to eq("unpaid")
      expect(result[:balances_restored]).to eq(1)
    end

    it "does not change balances during a dry run" do
      balance = build_balance
      build_payment(:payment_reversed, balances: [balance])

      result = described_class.process(dry_run: true)

      expect(balance.reload.state).to eq("processing")
      expect(result[:balances_would_restore]).to eq(1)
      expect(result[:balances_restored]).to eq(0)
    end

    it "leaves balances that are still held by an active payout untouched" do
      balance = build_balance
      build_payment(:payment_reversed, balances: [balance])
      build_payment(:payment, balances: [balance])

      result = described_class.process(dry_run: false)

      expect(balance.reload.state).to eq("processing")
      expect(result[:balances_skipped_still_held]).to eq(1)
      expect(result[:balances_restored]).to eq(0)
    end

    it "leaves balances held by a completed payout untouched" do
      balance = build_balance
      build_payment(:payment_reversed, balances: [balance])
      build_payment(:payment_completed, balances: [balance])

      result = described_class.process(dry_run: false)

      expect(balance.reload.state).to eq("processing")
      expect(result[:balances_skipped_still_held]).to eq(1)
      expect(result[:balances_restored]).to eq(0)
    end

    it "ignores Stripe payouts" do
      balance = build_balance
      build_payment(:payment_reversed, balances: [balance]).update_columns(processor: PayoutProcessorType::STRIPE)

      result = described_class.process(dry_run: false)

      expect(balance.reload.state).to eq("processing")
      expect(result[:payments_scanned]).to eq(0)
    end

    it "ignores reversed payouts whose balances already reverted to unpaid" do
      balance = build_balance(state: "unpaid")
      build_payment(:payment_reversed, balances: [balance])

      result = described_class.process(dry_run: false)

      expect(result[:payments_with_stuck_balances]).to eq(0)
      expect(result[:balances_restored]).to eq(0)
    end

    it "limits the sweep to the given payment_ids" do
      stuck_balance = build_balance
      target = build_payment(:payment_reversed, balances: [stuck_balance])

      other_balance = build_balance
      build_payment(:payment_reversed, balances: [other_balance])

      result = described_class.process(dry_run: false, payment_ids: [target.id])

      expect(stuck_balance.reload.state).to eq("unpaid")
      expect(other_balance.reload.state).to eq("processing")
      expect(result[:balances_restored]).to eq(1)
    end
  end
end
