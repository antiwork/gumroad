# frozen_string_literal: true

require "spec_helper"

describe User::PayoutInfo do
  let(:user) { create(:user, payment_address: "test@example.com", payouts_paused_internally: true) }
  let(:manual_payout_end_date) { Date.today }

  before do
    allow(User::PayoutSchedule).to receive(:manual_payout_end_date).and_return(manual_payout_end_date)
  end

  describe "#payout_info" do
    let!(:bank_account) { create(:uk_bank_account, user:) }
    let!(:comment) { create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED, content: "Paused due to review") }

    it "includes payout information" do
      result = user.payout_info

      expect(result[:active_bank_account]).to eq(
        "type" => bank_account.type,
        "account_holder_full_name" => bank_account.account_holder_full_name,
        "formatted_account" => bank_account.formatted_account
      )
      expect(result[:payment_address]).to eq("test@example.com")
      expect(result[:payouts_paused_by_source]).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
      expect(result[:payouts_paused_for_reason]).to eq("Paused due to review")
    end

    context "when there is no active bank account" do
      before do
        bank_account.destroy!
      end

      it "returns nil for active_bank_account" do
        result = user.payout_info

        expect(result[:active_bank_account]).to be_nil
      end
    end

    context "when there are no payouts_paused comments" do
      let!(:comment) { nil }

      it "returns nil for payouts_paused_for_reason" do
        result = user.payout_info

        expect(result[:payouts_paused_for_reason]).to be_nil
      end
    end

    context "when last payout is nil" do
      let!(:stripe_account) { create(:merchant_account, user:) }

      before do
        allow(user).to receive(:unpaid_balance_cents_up_to_date).with(manual_payout_end_date).and_return(10_000)
      end

      context "when user is payable via stripe from admin" do
        before do
          allow(Payouts).to receive(:is_user_payable)
            .with(user, manual_payout_end_date, processor_type: PayoutProcessorType::STRIPE, from_admin: true)
            .and_return(true)
          allow(Payouts).to receive(:is_user_payable)
            .with(user, manual_payout_end_date, processor_type: PayoutProcessorType::PAYPAL, from_admin: true)
            .and_return(false)
          allow(Payouts).to receive(:is_user_payable)
            .with(user, manual_payout_end_date, processor_type: PayoutProcessorType::STRIPE)
            .and_return(true)
          allow(user).to receive(:unpaid_balance_cents_up_to_date_held_by_gumroad).with(manual_payout_end_date).and_return(5_000)
          allow(user).to receive(:unpaid_balance_holding_cents_up_to_date_held_by_stripe).with(manual_payout_end_date).and_return(5_000)
        end

        it "includes manual payout info with stripe information" do
          result = user.payout_info

          expect(result[:manual_payout_info]).to eq(
            stripe: {
              unpaid_balance_held_by_gumroad: "$50",
              unpaid_balance_held_by_stripe: "50 USD"
            },
            paypal: nil,
            unpaid_balance_up_to_date: 10_000,
            currency: stripe_account.currency,
            manual_payout_period_end_date: manual_payout_end_date,
            ask_confirmation: false
          )
        end
      end

      context "when user is payable via paypal from admin" do
        before do
          allow(Payouts).to receive(:is_user_payable)
            .with(user, manual_payout_end_date, processor_type: PayoutProcessorType::STRIPE, from_admin: true)
            .and_return(false)
          allow(Payouts).to receive(:is_user_payable)
            .with(user, manual_payout_end_date, processor_type: PayoutProcessorType::PAYPAL, from_admin: true)
            .and_return(true)
          allow(Payouts).to receive(:is_user_payable)
            .with(user, manual_payout_end_date, processor_type: PayoutProcessorType::STRIPE)
            .and_return(false)
          allow(Payouts).to receive(:is_user_payable)
            .with(user, manual_payout_end_date, processor_type: PayoutProcessorType::PAYPAL)
            .and_return(true)
          allow(user).to receive(:should_paypal_payout_be_split?).and_return(true)
          allow(PaypalPayoutProcessor).to receive(:split_payment_by_cents).with(user).and_return(5_000)
        end

        it "includes manual payout info with paypal information" do
          result = user.payout_info

          expect(result[:manual_payout_info]).to eq(
            stripe: nil,
            paypal: {
              should_payout_be_split: true,
              split_payment_by_cents: 5_000
            },
            unpaid_balance_up_to_date: 10_000,
            currency: stripe_account.currency,
            manual_payout_period_end_date: manual_payout_end_date,
            ask_confirmation: false
          )
        end
      end

      context "when user is not payable via stripe or paypal from admin" do
        before do
          allow(Payouts).to receive(:is_user_payable)
            .with(user, manual_payout_end_date, processor_type: PayoutProcessorType::STRIPE, from_admin: true)
            .and_return(false)
          allow(Payouts).to receive(:is_user_payable)
            .with(user, manual_payout_end_date, processor_type: PayoutProcessorType::PAYPAL, from_admin: true)
            .and_return(false)
        end

        it "does not include manual payout info" do
          result = user.payout_info

          expect(result[:manual_payout_info]).to be_nil
        end
      end
    end

    context "when last payout exists" do
      let!(:payment) { create(:payment, user:) }

      it "does not include manual payout info" do
        result = user.payout_info

        expect(result[:manual_payout_info]).to be_nil
      end
    end
  end
end
