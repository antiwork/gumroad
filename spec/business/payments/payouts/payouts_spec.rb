# frozen_string_literal: true

require "spec_helper"

describe Payouts do
  describe "is_user_payable" do
    let(:payout_date) { Date.today - 1 }

    it "returns false for creators with paused payouts" do
      creator = create(:user, payment_address: "payme@example.com", payouts_paused_internally: true)
      create(:balance, user: creator, amount_cents: 100_001, date: 3.days.ago)

      expect(described_class.is_user_payable(creator, payout_date)).to be(false)
    end

    describe "risk state" do
      def expect_processors_not_called
        PayoutProcessorType.all.each do |payout_processor_type|
          expect(PayoutProcessorType.get(payout_processor_type)).not_to receive(:is_user_payable)
        end
      end

      it "returns false for creators suspended for TOS violation" do
        expect_processors_not_called
        creator = create(:user, payment_address: "payme@example.com", user_risk_state: "suspended_for_tos_violation")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(false)
      end

      it "returns false for creators suspended for fraud" do
        expect_processors_not_called
        creator = create(:user, payment_address: "payme@example.com", user_risk_state: "suspended_for_fraud")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(false)
      end

      it "returns true for creators that are compliant" do
        creator = create(:singaporean_user_with_compliance_info, payment_address: "payme@example.com", user_risk_state: "compliant")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(true)
      end

      it "returns true for compliant creators who have a PayPal account connected", :vcr do
        creator = create(:singaporean_user_with_compliance_info, payment_address: "", user_risk_state: "compliant")
        create(:merchant_account_paypal, user: creator, charge_processor_merchant_id: "B66YJBBNCRW6L")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(true)
      end

      it "returns false for accounts not reviewed" do
        expect_processors_not_called
        creator = create(:user, payment_address: "payme@example.com", user_risk_state: "not_reviewed")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(false)
      end

      it "returns false for accounts on probation" do
        expect_processors_not_called
        creator = create(:user, payment_address: "payme@example.com", user_risk_state: "on_probation")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(false)
      end

      it "returns false for accounts flagged for terms violation" do
        expect_processors_not_called
        creator = create(:user, payment_address: "payme@example.com", user_risk_state: "flagged_for_tos_violation")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(false)
      end

      it "returns false for accounts flagged for fraud" do
        expect_processors_not_called
        creator = create(:user, payment_address: "payme@example.com", user_risk_state: "flagged_for_fraud")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(false)
      end

      describe "non-compliant user from admin" do
        let(:payout_date) { Date.today }
        let(:user) { create(:tos_user, payment_address: "bob1@example.com") }

        before do
          create(:balance, user: user, amount_cents: 1001, date: payout_date - 3)
          create(:user_compliance_info, user:)
        end

        it "returns true" do
          expect(described_class.is_user_payable(user, payout_date, from_admin: true)).to eq(true)
        end
      end
    end

    describe "unpaid balance" do
      let(:payout_date) { Date.today }
      let(:u1) { create(:singaporean_user_with_compliance_info, user_risk_state: "compliant", payment_address: "bob1@example.com") }
      let(:u1b1) { create(:balance, user: u1, amount_cents: 499, date: payout_date - 3) }
      let(:u1b2) { create(:balance, user: u1, amount_cents: 501, date: payout_date - 2) }

      describe "enough money in balance to meet minimum" do
        before { u1b1 && u1b2 }

        it "considers the user payable" do
          expect(described_class.is_user_payable(u1, payout_date)).to eq(true)
        end
      end

      describe "not enough money in balance to meet minimum" do
        before { u1b1 }

        describe "no other paid balances for the same payout date" do
          it "considers the user NOT payable" do
            expect(described_class.is_user_payable(u1, payout_date)).to eq(false)
          end
        end

        describe "paid balances for the same payout date" do
          let(:u1p1) { create(:payment_completed, user: u1, payout_period_end_date: payout_date, amount_cents: 501) }

          before { u1b1 && u1p1 }

          it "considers the user payable" do
            expect(described_class.is_user_payable(u1, payout_date)).to eq(true)
          end
        end

        describe "returned balances for the same payout date" do
          let(:u1p1) { create(:payment_returned, user: u1, payout_period_end_date: payout_date, amount_cents: 501) }

          before { u1p1 }

          it "considers the user NOT payable" do
            expect(described_class.is_user_payable(u1, payout_date)).to eq(false)
          end
        end
      end
    end

    describe "instant payouts" do
      let(:seller) { create(:compliant_user) }

      before do
        allow(StripePayoutProcessor).to receive(:is_user_payable).and_return(true)
        create(:balance, user: seller, amount_cents: 50_00, date: payout_date - 3)
      end

      it "returns true when instant payouts are supported and the user has an eligible balance" do
        allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(true)
        expect(described_class.is_user_payable(seller, payout_date, payout_type: Payouts::PAYOUT_TYPE_INSTANT)).to be(true)
      end

      it "returns false when instant payouts are not supported" do
        allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(false)
        expect(described_class.is_user_payable(seller, payout_date, payout_type: Payouts::PAYOUT_TYPE_INSTANT)).to be(false)
      end

      it "calls the stripe payout processor with only the instantly payable balance amount" do
        allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(true)
        allow_any_instance_of(User).to receive(:instantly_payable_unpaid_balance_cents_up_to_date).and_return(100_00)
        allow_any_instance_of(User).to receive(:unpaid_balance_cents_up_to_date).and_return(200_00)
        expect(StripePayoutProcessor).to receive(:is_user_payable).with(seller, 100_00, add_comment: false, from_admin: false, payout_type: anything)
        described_class.is_user_payable(seller, payout_date, payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      end
    end

    describe "payout processor logic" do
      let(:u1) { create(:compliant_user) }

      before do
        create(:balance, user: u1, amount_cents: 49_99, date: payout_date - 2)
        create(:balance, user: u1, amount_cents: 50_01, date: payout_date - 1)
      end

      describe "no payout processor type specified" do
        it "asks all payout processors" do
          expect(PaypalPayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything)
          expect(StripePayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything)
          described_class.is_user_payable(u1, payout_date)
        end

        describe "all processors say no" do
          before do
            allow(PaypalPayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(false)
            allow(StripePayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(false)
          end

          it "considers the user NOT payable" do
            expect(described_class.is_user_payable(u1, payout_date)).to eq(false)
          end
        end

        describe "one processor says yes, rest say no" do
          before do
            allow(PaypalPayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(false)
            allow(StripePayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(true)
          end

          it "considers the user payable" do
            expect(described_class.is_user_payable(u1, payout_date)).to eq(true)
          end
        end

        describe "all processors say yes" do
          before do
            allow(PaypalPayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(true)
            allow(StripePayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(true)
          end

          it "considers the user payable" do
            expect(described_class.is_user_payable(u1, payout_date)).to eq(true)
          end
        end
      end

      describe "a payout processor type specified" do
        let(:payout_processor_type) { PayoutProcessorType::STRIPE }

        it "asks only that payout processors" do
          expect(PaypalPayoutProcessor).to_not receive(:is_user_payable).with(u1, 100_00, add_comment: anything, payout_type: anything)
          expect(StripePayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything)
          described_class.is_user_payable(u1, payout_date, processor_type: payout_processor_type)
        end

        describe "processor says no" do
          before do
            allow(StripePayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(false)
          end

          it "considers the user NOT payable" do
            expect(described_class.is_user_payable(u1, payout_date, processor_type: payout_processor_type)).to eq(false)
          end
        end

        describe "processor says yes" do
          before do
            allow(StripePayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(true)
          end

          it "considers the user payable" do
            expect(described_class.is_user_payable(u1, payout_date, processor_type: payout_processor_type)).to eq(true)
          end
        end
      end
    end
  end

  describe "create_payments_for_balances_up_to_date" do
    let(:payout_date) { Date.yesterday }
    let(:payout_processor_type) { PayoutProcessorType::PAYPAL }

    it "calls on create_payments_for_balances_up_to_date_for_users with all users holding balance" do
      create(:user, unpaid_balance_cents: 0)
      u2 = create(:user, unpaid_balance_cents: 1)
      u3 = create(:user, unpaid_balance_cents: 10)
      u4 = create(:user, unpaid_balance_cents: 1000)
      expect(described_class).to receive(:create_payments_for_balances_up_to_date_for_users).with(payout_date, payout_processor_type, [u2, u3, u4], perform_async: true)
      described_class.create_payments_for_balances_up_to_date(payout_date, payout_processor_type)
    end

    it "calls create_payments_for_balances_up_to_date_for_users with all users holding balance who have an active Stripe Connect account" do
      u1 = create(:user, unpaid_balance_cents: 0) # Has an active Stripe Connect account but no balance
      u2 = create(:user, unpaid_balance_cents: 200) # Has balance and a Stripe account but no Stripe Connect account
      u3 = create(:user, unpaid_balance_cents: 100) # Has balance and an active Stripe Connect account
      u4 = create(:user, unpaid_balance_cents: 1000) # Has balance and an inactive Stripe Connect account
      create(:user, unpaid_balance_cents: 1000) # Has balance but no Stripe or Stripe Connect account

      create(:merchant_account_stripe_connect, charge_processor_merchant_id: "stripe_connect_u1", user: u1)
      create(:merchant_account, charge_processor_merchant_id: "stripe_u2", user: u2)
      create(:merchant_account_stripe_connect, charge_processor_merchant_id: "stripe_connect_u3", user: u3)
      create(:merchant_account_stripe_connect, charge_processor_merchant_id: "stripe_connect_u4", user: u4, deleted_at: Time.current)

      expect(described_class).to receive(:create_payments_for_balances_up_to_date_for_users).with(payout_date, PayoutProcessorType::STRIPE, [u3], perform_async: true)

      described_class.create_payments_for_balances_up_to_date(payout_date, PayoutProcessorType::STRIPE)
    end
  end

  describe "create_instant_payouts_for_balances_up_to_date" do
    let(:payout_date) { Date.yesterday }

    it "calls create_instant_payouts_for_balances_up_to_date_for_users with all users holding balance with a payout frequency of daily" do
      create(:user, unpaid_balance_cents: 0, payout_frequency: User::PayoutSchedule::WEEKLY)
      create(:user, unpaid_balance_cents: 100, payout_frequency: User::PayoutSchedule::WEEKLY)
      create(:user, unpaid_balance_cents: 0, payout_frequency: User::PayoutSchedule::DAILY)
      u4 = create(:user, unpaid_balance_cents: 100, payout_frequency: User::PayoutSchedule::DAILY)

      expect(described_class).to receive(:create_instant_payouts_for_balances_up_to_date_for_users).with(payout_date, [u4], perform_async: true, add_comment: true)

      described_class.create_instant_payouts_for_balances_up_to_date(payout_date)
    end
  end

  describe "create_instant_payouts_for_balances_up_to_date_for_users" do
    let(:payout_date) { Date.yesterday }

    context "when the seller does not support instant payouts" do
      it "does not create payments" do
        creator = create(:user_with_compliance_info)
        allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(false)

        expect do
          described_class.create_instant_payouts_for_balances_up_to_date_for_users(payout_date, [creator])
        end.to_not change { Payment.count }
      end
    end
  end

  describe ".create_payments_for_balances_up_to_date_for_bank_account_types" do
    let(:payout_date) { Date.today - 1 }
    let(:payout_processor_type) { PayoutProcessorType::STRIPE }

    let(:u0_0) do
      create(:user, unpaid_balance_cents: 0)
    end
    let(:u0_1) do
      user = create(:user, unpaid_balance_cents: 0)
      create(:ach_account, user:)
      user
    end
    let(:u0_2) do
      user = create(:user, unpaid_balance_cents: 0)
      create(:australian_bank_account, user:)
      user
    end
    before { u0_0 && u0_1 && u0_2 }

    let(:u1_0) do
      create(:user, unpaid_balance_cents: 10_00)
    end
    let(:u1_1) do
      user = create(:user, unpaid_balance_cents: 10_00)
      create(:ach_account, user:)
      user
    end
    let(:u1_2) do
      user = create(:user, unpaid_balance_cents: 10_00)
      create(:australian_bank_account, user:)
      user
    end
    before { u1_0 && u1_1 && u1_2 }

    let(:u2_0) do
      create(:user, unpaid_balance_cents: 100_00)
    end
    let(:u2_1) do
      user = create(:user, unpaid_balance_cents: 100_00)
      create(:ach_account, user:)
      user
    end
    let(:u2_2) do
      user = create(:user, unpaid_balance_cents: 100_00)
      create(:australian_bank_account, user:).mark_deleted!
      create(:australian_bank_account, user:)
      user
    end
    before { u2_0 && u2_1 && u2_2 }

    let(:u3_0) do
      user = create(:user, unpaid_balance_cents: 100_00)
      create(:canadian_bank_account, user:)
      user
    end
    before { u3_0 }

    it "calls create_payments_for_balances_up_to_date_for_users for users holding balance once for every bank account type" do
      allow(Payouts).to receive(:is_user_payable).exactly(3).times.and_return(true)
      expect(described_class).to receive(:create_payments_for_balances_up_to_date_for_users).with(payout_date, payout_processor_type, [u1_2, u2_2], perform_async: true, bank_account_type: "AustralianBankAccount").and_call_original
      expect(described_class).to receive(:create_payments_for_balances_up_to_date_for_users).with(payout_date, payout_processor_type, [u3_0], perform_async: true, bank_account_type: "CanadianBankAccount").and_call_original

      described_class.create_payments_for_balances_up_to_date_for_bank_account_types(payout_date, payout_processor_type, [AustralianBankAccount.name, CanadianBankAccount.name])
    end
  end

  describe "create_payments_for_balances_up_to_date_for_users" do
    context "when payouts are paused for the seller" do
      it "does not create payments" do
        creator = create(:user_with_compliance_info, payouts_paused_internally: true)
        create(:merchant_account, user: creator)
        create(:ach_account, user: creator, stripe_bank_account_id: "ba_bankaccountid")
        create(:balance, user: creator, amount_cents: 100_001, date: 20.days.ago)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(10.days.ago, PayoutProcessorType::STRIPE, [creator])
        end.to_not change { Payment.count }
      end
    end

    describe "attempting to payout for today" do
      it "raises an argument error" do
        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today, PayoutProcessorType::PAYPAL, [])
        end.to raise_error(ArgumentError)
      end
    end

    describe "attempting to payout for a future date" do
      it "raises an argument error" do
        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today + 10, PayoutProcessorType::PAYPAL, [])
        end.to raise_error(ArgumentError)
      end
    end

    describe "payout schedule" do
      let(:seller) { create(:compliant_user, payment_address: "seller@example.com") }
      let(:payout_date) { Date.today - 1 }

      before do
        create(:balance, user: seller, date: payout_date - 3, amount_cents: 1000_00)
      end

      it "does not create payments if next_payout_date does not match payout date" do
        allow(seller).to receive(:next_payout_date).and_return(payout_date + 1.week)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(payout_date, PayoutProcessorType::PAYPAL, [seller])
        end.not_to change { Payment.count }
      end
    end

    describe "payout skipped notes" do
      it "adds a comment if payout is skipped due to low balance", :vcr do
        payout_time = Date.today.in_time_zone("UTC").beginning_of_week(:friday).change(hour: 10)
        travel_to payout_time + 1.day

        seller = create(:compliant_user, payment_address: "seller@gr.co")
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 900)
        seller2 = create(:compliant_user, payment_address: "seller@gr.co")
        create(:user_compliance_info, user: seller2)
        create(:balance, user: seller2, date: Date.today - 3, amount_cents: 1000)
        seller3 = create(:compliant_user, payment_address: "seller@gr.co")
        create(:user_compliance_info, user: seller3)
        expect(seller3.unpaid_balance_cents).to eq(0)

        expect do
          expect do
            expect do
              described_class.create_payments_for_balances_up_to_date_for_users(payout_time.to_date, PayoutProcessorType::PAYPAL, [seller, seller2])
            end.to change { seller.comments.with_type_payout_note.count }.by(1)
          end.not_to change { seller2.comments.count }
        end.not_to change { seller3.comments.count }

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Payout on #{date} was skipped because the account balance $9 USD was less than the minimum payout amount of $10 USD."
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)
      end

      it "adds a comment if payout is skipped because the account is suspended" do
        seller = create(:user, user_risk_state: "suspended_for_fraud", payment_address: "seller@gr.co")
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Payout on #{date} was skipped because the account was not compliant."
        expect(seller.comments.with_type_payout_note.count).to eq 1
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)

        seller.update!(user_risk_state: "suspended_for_tos_violation")

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        expect(seller.comments.with_type_payout_note.count).to eq 2
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)
      end

      it "adds a comment if payout is skipped because payouts are paused by admin" do
        seller = create(:compliant_user, payment_address: "seller@gr.co")
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)
        seller.update!(payouts_paused_internally: true)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Payout on #{date} was skipped because payouts on the account were paused by the admin."
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)
      end

      it "adds a comment if payout is skipped because payouts are paused by stripe" do
        seller = create(:compliant_user)
        create(:ach_account, user: seller)
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Payout on #{date} was skipped because payouts on the account were paused by the payout processor."
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)
      end

      it "adds a comment if payout is skipped because payouts are paused by the system" do
        seller = create(:compliant_user)
        create(:ach_account, user: seller)
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Payout on #{date} was skipped because payouts on the account were paused by the system."
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)
      end

      it "adds a comment if payout is skipped because payouts are paused by the seller" do
        seller = create(:compliant_user)
        create(:ach_account, user: seller)
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)
        seller.update!(payouts_paused_by_user: true)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Payout on #{date} was skipped because payouts on the account were paused by the user."
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)
      end
    end

    describe "slack notification" do
      before do
        @seller = create(:compliant_user, payment_address: "seller@gr.co")
        create(:balance, user: @seller, date: Date.today - 3, amount_cents: 900)
        @seller2 = create(:compliant_user, payment_address: "seller@gr.co")
        create(:balance, user: @seller2, date: Date.today - 3, amount_cents: 1000)
      end

      it "sends a started scheduling payouts message when scheduling payouts" do
        allow(Payouts).to receive(:is_user_payable).twice.and_return(true)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [@seller, @seller2], perform_async: true)
      end

      it "sends a retrying message when retrying failed payouts" do
        allow(Payouts).to receive(:is_user_payable).twice.and_return(true)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [@seller, @seller2], perform_async: true, retrying: true)
      end

      it "includes the country info if payouts are for creators of a specific country" do
        seller = create(:user, unpaid_balance_cents: 100_00)
        create(:canadian_bank_account, user: seller)
        seller2 = create(:user, unpaid_balance_cents: 50_00)
        create(:canadian_bank_account, user: seller2)
        seller3 = create(:user, unpaid_balance_cents: 20_00)
        create(:korea_bank_account, user: seller3)
        seller4 = create(:user, unpaid_balance_cents: 220_00)
        create(:korea_bank_account, user: seller4)
        seller5 = create(:user, unpaid_balance_cents: 120_00)
        create(:korea_bank_account, user: seller5)
        seller6 = create(:user, unpaid_balance_cents: 120_00)
        create(:european_bank_account, user: seller6)
        seller7 = create(:user, unpaid_balance_cents: 120_00)
        create(:european_bank_account, user: seller7)

        allow(Payouts).to receive(:is_user_payable).exactly(7).times.and_return(true)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller, seller2], perform_async: true, bank_account_type: "CanadianBankAccount")
        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller3, seller4, seller5], perform_async: true, bank_account_type: "KoreaBankAccount")
        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller6, seller7], perform_async: true, bank_account_type: "EuropeanBankAccount")
      end

      it "includes the bank or debit card info if payouts are for creators from US", :vcr do
        seller = create(:user, unpaid_balance_cents: 100_00)
        create(:ach_account, user: seller)
        seller2 = create(:user, unpaid_balance_cents: 100_00)
        create(:ach_account, user: seller2)
        seller3 = create(:user, unpaid_balance_cents: 100_00)
        create(:ach_account, user: seller3)
        seller4 = create(:user, unpaid_balance_cents: 50_00)
        create(:card_bank_account, user: seller4)
        seller5 = create(:user, unpaid_balance_cents: 50_00)
        create(:card_bank_account, user: seller5)
        seller6 = create(:user, unpaid_balance_cents: 50_00)
        create(:card_bank_account, user: seller6)
        seller7 = create(:user, unpaid_balance_cents: 50_00)
        create(:card_bank_account, user: seller7)

        allow(Payouts).to receive(:is_user_payable).exactly(7).times.and_return(true)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller, seller2, seller3], perform_async: true, bank_account_type: "AchAccount")
        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller4, seller5, seller6, seller7], perform_async: true, bank_account_type: "CardBankAccount")
      end

      it "includes the Stripe Connect info for Stripe payouts without a bank account type" do
        seller = create(:user, unpaid_balance_cents: 100_00)
        create(:merchant_account_stripe_connect, user: seller)
        seller2 = create(:user, unpaid_balance_cents: 100_00)
        create(:merchant_account_stripe_connect, user: seller2)

        allow(Payouts).to receive(:is_user_payable).exactly(2).times.and_return(true)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller, seller2], perform_async: true)
      end
    end

    describe "a user is payable but balances are changed (e.g. by a chargeback) and will make for a negative payment" do
      let(:payout_date) { Date.today - 1 }
      let(:payout_processor_type) { PayoutProcessorType::PAYPAL }

      let(:u1) { create(:user) }
      let(:u1a1) { create(:ach_account, user: u1) }
      let(:u1b1) { create(:balance, user: u1, date: payout_date - 3, amount_cents: 1_00) }
      let(:u1b2) { create(:balance, user: u1, date: payout_date - 2, amount_cents: -15_00) }

      before do
        u1 && u1a1 && u1b1 && u1b2
        expect(described_class).to receive(:is_user_payable).and_return(true) # let the user be thought to be payable on the initial check
      end

      let(:create_payments_for_balances_up_to_date_for_users) do
        described_class.create_payments_for_balances_up_to_date_for_users(payout_date, payout_processor_type, [u1])
      end

      it "remarks the balances as unpaid" do
        create_payments_for_balances_up_to_date_for_users
        expect(u1b1.reload.state).to eq("unpaid")
        expect(u1b2.reload.state).to eq("unpaid")
      end

      it "does not alter the user's balance" do
        create_payments_for_balances_up_to_date_for_users
        expect(u1.reload.unpaid_balance_cents).to eq(-14_00)
      end

      it "does not create a payment" do
        expect { create_payments_for_balances_up_to_date_for_users }.to_not change { Payment.count }
      end
    end
  end
end
