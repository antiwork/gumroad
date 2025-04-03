# frozen_string_literal: true

require "spec_helper"

describe PayoutEstimates do
  describe "estimate_held_amount_cents" do
    let(:payout_date) { Date.today - 1 }
    let(:payout_processor_type) { PayoutProcessorType::STRIPE }

    # user who has some balances in the payout period and out of it
    let(:u0) { create(:user_with_compliance_info) }
    let(:u0m1) { create(:merchant_account, user: u0, charge_processor_id: StripeChargeProcessor.charge_processor_id) }
    let(:u0a1) { create(:ach_account, user: u0, stripe_bank_account_id: "ba_1234") }
    let(:u0b1) { create(:balance, user: u0, date: payout_date - 3, amount_cents:   1_00, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)) }
    let(:u0b2) { create(:balance, user: u0, date: payout_date - 2, amount_cents: 10_00, merchant_account: u0m1) }
    let(:u0b3) { create(:balance, user: u0, date: payout_date + 1, amount_cents: 100_00, merchant_account: u0m1) }
    before { u0 && u0m1 && u0a1 && u0b1 && u0b2 && u0b3 }

    # user who has some balances in the payout period and out of it
    let(:u1) { create(:user_with_compliance_info) }
    let(:u1m1) { create(:merchant_account, user: u1, charge_processor_id: StripeChargeProcessor.charge_processor_id) }
    let(:u1a1) { create(:ach_account, user: u1, stripe_bank_account_id: "ba_1234") }
    let(:u1b1) { create(:balance, user: u1, date: payout_date - 3, amount_cents:   1_00, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)) }
    let(:u1b2) { create(:balance, user: u1, date: payout_date - 2, amount_cents: 10_00, merchant_account: u1m1) }
    let(:u1b3) { create(:balance, user: u1, date: payout_date + 1, amount_cents: 100_00, merchant_account: u1m1) }
    before { u1 && u1m1 && u1a1 && u1b1 && u1b2 && u1b3 }

    # user who doesn't have enough in balances to be paid out, but has a payment already made for the same period which makes it enough
    let(:u2) { create(:user_with_compliance_info) }
    let(:u2m1) { create(:merchant_account, user: u2, charge_processor_id: StripeChargeProcessor.charge_processor_id) }
    let(:u2a1) { create(:ach_account, user: u2, stripe_bank_account_id: "ba_1235") }
    let(:u2p1) { create(:payment_completed, user: u2, payout_period_end_date: payout_date, amount_cents: 10_00) }
    let(:u2b1) { create(:balance, user: u2, date: payout_date - 2, amount_cents: 1_00, merchant_account: u2m1) }
    let(:u2b2) { create(:balance, user: u2, date: payout_date - 1, amount_cents: 5_00, merchant_account: u2m1) }
    before { u2 && u2m1 && u2a1 && u2p1 && u2b1 && u2b2 }

    # user who doesn't have enough in balances to be paid out
    let(:u3) { create(:user_with_compliance_info) }
    let(:u3m1) { create(:merchant_account, user: u3, charge_processor_id: StripeChargeProcessor.charge_processor_id) }
    let(:u3a1) { create(:ach_account, user: u3, stripe_bank_account_id: "ba_1236") }
    let(:u3b1) { create(:balance, user: u3, date: payout_date - 2, amount_cents: 1_00, merchant_account: u3m1) }
    before { u3 && u3m1 && u3a1 && u3b1 }

    let(:estimate_held_amount_cents) do
      subject.estimate_held_amount_cents(payout_date, payout_processor_type)
    end

    it "returns the aggregate of the amount being held at each holder of funds" do
      User.holding_balance.update_all(user_risk_state: "compliant")
      holder_of_funds_amount_cents = estimate_held_amount_cents
      expect(holder_of_funds_amount_cents[HolderOfFunds::STRIPE]).to eq(26_00)
      expect(holder_of_funds_amount_cents[HolderOfFunds::GUMROAD]).to eq(2_00)
    end
  end

  describe "estimate_payments_for_balances_up_to_date_for_users" do
    describe "common payment cases (ACH via Stripe)" do
      let(:payout_date) { Date.today - 1 }
      let(:payout_processor_type) { PayoutProcessorType::STRIPE }

      # user who has some balances in the payout period and out of it
      let(:u1) { create(:user_with_compliance_info) }
      let(:u1m1) { create(:merchant_account, user: u1, charge_processor_id: StripeChargeProcessor.charge_processor_id) }
      let(:u1a1) { create(:ach_account, user: u1, stripe_bank_account_id: "ba_123") }
      let(:u1b1) { create(:balance, user: u1, date: payout_date - 3, amount_cents: 1_00) }
      let(:u1b2) { create(:balance, user: u1, date: payout_date - 2, amount_cents: 10_00) }
      let(:u1b3) { create(:balance, user: u1, date: payout_date + 1, amount_cents: 100_00) }
      before { u1 && u1m1 && u1a1 && u1b1 && u1b2 && u1b3 }

      # user who doesn't have enough in balances to be paid out, but has a payment already made for the same period which makes it enough
      let(:u2) { create(:user_with_compliance_info) }
      let(:u2m1) { create(:merchant_account, user: u2, charge_processor_id: StripeChargeProcessor.charge_processor_id) }
      let(:u2a1) { create(:ach_account, user: u2, stripe_bank_account_id: "ba_1234") }
      let(:u2p1) { create(:payment_completed, user: u2, payout_period_end_date: payout_date, amount_cents: 10_00) }
      let(:u2b1) { create(:balance, user: u2, date: payout_date - 2, amount_cents: 1_00) }
      let(:u2b2) { create(:balance, user: u2, date: payout_date - 1, amount_cents: 5_00) }
      before { u2 && u2m1 && u2a1 && u2p1 && u2b1 && u2b2 }

      # user who doesn't have enough in balances to be paid out
      let(:u3) { create(:user_with_compliance_info) }
      let(:u3m1) { create(:merchant_account, user: u3, charge_processor_id: StripeChargeProcessor.charge_processor_id) }
      let(:u3a1) { create(:ach_account, user: u3, stripe_bank_account_id: "ba_12345") }
      let(:u3b1) { create(:balance, user: u3, date: payout_date - 2, amount_cents: 1_00) }
      before { u3 && u3m1 && u3a1 && u3b1 }

      let(:users) { [u1, u2, u3] }

      let(:estimate_payments_for_balances_up_to_date_for_users) do
        subject.estimate_payments_for_balances_up_to_date_for_users(payout_date, payout_processor_type, users)
      end

      it "does not mark the balances that will be paid as processing" do
        estimate_payments_for_balances_up_to_date_for_users
        expect(u1b1.reload.state).to eq("unpaid")
        expect(u1b2.reload.state).to eq("unpaid")
        expect(u2b1.reload.state).to eq("unpaid")
        expect(u2b2.reload.state).to eq("unpaid")
      end

      it "does not mark the balances not being paid as processing" do
        estimate_payments_for_balances_up_to_date_for_users
        expect(u1b3.reload.state).to eq("unpaid")
        expect(u3b1.reload.state).to eq("unpaid")
      end

      it "does not deduct the balance from the user" do
        estimate_payments_for_balances_up_to_date_for_users
        expect(u1.unpaid_balance_cents).to eq(111_00)
        expect(u2.unpaid_balance_cents).to eq(6_00)
        expect(u3.unpaid_balance_cents).to eq(1_00)
      end

      it "does not create payments for the payable users, up to the date" do
        expect { estimate_payments_for_balances_up_to_date_for_users }.not_to change { [u1.payments, u2.payments, u3.payments] }
      end

      it "generates payment estimates containing info about where funds are held" do
        expect(estimate_payments_for_balances_up_to_date_for_users).to eq(
          [
            {
              user: u1,
              amount_cents: 11_00,
              holder_of_funds_amount_cents: { "gumroad" => 11_00 }
            },
            {
              user: u2,
              amount_cents: 6_00,
              holder_of_funds_amount_cents: { "gumroad" => 6_00 }
            }
          ]
        )
      end
    end
  end
end
