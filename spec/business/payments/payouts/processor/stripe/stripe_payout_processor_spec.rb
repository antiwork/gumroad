# frozen_string_literal: true

require "spec_helper"

describe StripePayoutProcessor, :vcr do
  include CurrencyHelper
  include StripeChargesHelper

  describe "is_user_payable" do
    before do
      # sufficient balance for US USD payout
      @u1 = create(:compliant_user, unpaid_balance_cents: 10_01)
      @m1 = create(:merchant_account, user: @u1)
      @b1 = create(:ach_account, user: @u1, stripe_bank_account_id: "ba_bankaccountid")
      create(:user_compliance_info, user: @u1)

      # insufficient balance for KOR KRW payout
      @u2 = create(:compliant_user, unpaid_balance_cents: 10_01)
      @m2 = create(:merchant_account_stripe_korea, user: @u2)
      @b2 = create(:korea_bank_account, user: @u2, stripe_bank_account_id: "ba_korbankaccountid")
    end

    describe "creator no longer has an ach account" do
      before do
        @b1.mark_deleted!
      end

      it "returns false" do
        expect(described_class.is_user_payable(@u1, 10_01)).to eq(false)
      end

      it "adds a payout skipped note if the flag is set" do
        expect do
          described_class.is_user_payable(@u1, 10_01)
        end.not_to change { @u1.comments.with_type_payout_note.count }

        expect do
          described_class.is_user_payable(@u1, 10_01, add_comment: true)
        end.to change { @u1.comments.with_type_payout_note.count }.by(1)

        content = "Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because a bank account wasn't added at the time."
        expect(@u1.comments.with_type_payout_note.last.content).to eq(content)
      end
    end

    describe "creator has a ach account without a corresponding stripe id" do
      before do
        @b1.stripe_bank_account_id = nil
        @b1.save!
      end

      it "returns false" do
        expect(described_class.is_user_payable(@u1, 10_01)).to eq(false)
      end

      it "adds a payout skipped note if the flag is set" do
        expect do
          described_class.is_user_payable(@u1, 10_01)
        end.not_to change { @u1.comments.with_type_payout_note.count }

        expect do
          described_class.is_user_payable(@u1, 10_01, add_comment: true)
        end.to change { @u1.comments.with_type_payout_note.count }.by(1)

        content = "Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because the payout bank account was not correctly set up."
        expect(@u1.comments.with_type_payout_note.last.content).to eq(content)
      end
    end

    describe "creator does not have a merchant account" do
      before do
        @m1.mark_deleted!
        @u1.reload
      end

      it "returns false" do
        expect(described_class.is_user_payable(@u1, 10_01)).to eq(false)
      end

      it "adds a payout skipped note if the flag is set" do
        expect do
          described_class.is_user_payable(@u1, 10_01)
        end.not_to change { @u1.comments.with_type_payout_note.count }

        expect do
          described_class.is_user_payable(@u1, 10_01, add_comment: true)
        end.to change { @u1.comments.with_type_payout_note.count }.by(1)

        content = "Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because the payout bank account was not correctly set up."
        expect(@u1.comments.with_type_payout_note.last.content).to eq(content)
      end
    end

    it "returns true when the user is marked as compliant" do
      expect(described_class.is_user_payable(@u1, 10_01)).to eq(true)
    end

    describe "when the user has a previous payout in processing state" do
      before do
        @payout1 = create(:payment, user: @u1, processor: "STRIPE", processor_fee_cents: 10,
                                    stripe_transfer_id: "tr_1234", stripe_connect_account_id: "acct_1234")
        @payout2 = create(:payment, user: @u1, processor: "STRIPE", processor_fee_cents: 20,
                                    stripe_transfer_id: "tr_5678", stripe_connect_account_id: "acct_1234")
      end

      it "returns false" do
        expect(described_class.is_user_payable(@u1, 10_01)).to eq(false)

        @u1.payments.processing.each { |payment| payment.mark_completed! }
        expect(described_class.is_user_payable(@u1, 10_01)).to eq(true)
      end

      it "adds a payout skipped note if the flag is set" do
        expect do
          described_class.is_user_payable(@u1, 10_01)
        end.not_to change { @u1.comments.with_type_payout_note.count }

        expect do
          described_class.is_user_payable(@u1, 10_01, add_comment: true)
        end.to change { @u1.comments.with_type_payout_note.count }.by(1)

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Payout on #{date} was skipped because there was already a payout in processing."
        expect(@u1.comments.with_type_payout_note.last.content).to eq(content)
      end
    end

    describe "creator has a Stripe Connect account" do
      before do
        @m1.mark_deleted!
        @b1.mark_deleted!
        @u1.update_columns(user_risk_state: "compliant")
        expect_any_instance_of(User).to receive(:merchant_migration_enabled?).and_return true
        create(:merchant_account_stripe_connect, user: @u1)
        @u1.reload
      end

      it "returns true" do
        expect(described_class.is_user_payable(@u1, 10_01)).to eq(true)
      end

      it "returns false if Stripe Connect account is from Brazil" do
        @u1.stripe_connect_account.mark_deleted!
        create(:merchant_account_stripe_connect, user: @u1, country: "BR", currency: "brl")
        expect(described_class.is_user_payable(@u1, 10_01)).to eq(false)
      end
    end
  end

  describe "has_valid_payout_info?" do
    let(:user) { create(:compliant_user) }

    before do
      create(:merchant_account, user:)
      create(:ach_account, user:, stripe_bank_account_id: "ba_bankaccountid")
    end

    it "returns true if the user otherwise has valid payout info" do
      expect(user.has_valid_payout_info?).to eq true
    end

    it "returns false if the user does not have an active bank account" do
      user.active_bank_account.destroy!
      expect(user.has_valid_payout_info?).to eq false
    end

    it "returns false if the user's bank account is not linked to Stripe" do
      user.active_bank_account.update!(stripe_bank_account_id: "")
      expect(user.has_valid_payout_info?).to eq false
    end

    it "returns false if the user does not have a Stripe account" do
      user.stripe_account.destroy!
      expect(user.has_valid_payout_info?).to eq false
    end

    it "returns true if the user has a connected Stripe account regardless of other checks" do
      allow(user).to receive(:has_stripe_account_connected?).and_return(true)
      user.active_bank_account.destroy!
      expect(user.has_valid_payout_info?).to eq true
    end
  end

  describe "is_balance_payable" do
    describe "balance is associated with a Gumroad merchant account" do
      let(:balance) { create(:balance) }

      it "returns true" do
        expect(described_class.is_balance_payable(balance)).to eq(true)
      end
    end

    describe "balance is associated with a Creators' merchant account" do
      let(:merchant_account) { create(:merchant_account) }
      let(:balance) { create(:balance, merchant_account:) }

      it "returns false" do
        expect(described_class.is_balance_payable(balance)).to eq(true)
      end
    end

    describe "balance is associated with a Creators' merchant account but in the wrong currency for some reason" do
      let(:merchant_account) { create(:merchant_account, currency: Currency::USD) }
      let(:balance) { create(:balance, merchant_account:, currency: Currency::CAD) }

      it "returns false" do
        expect(described_class.is_balance_payable(balance)).to eq(false)
      end
    end
  end

  describe "prepare_payment_and_set_amount" do
    let(:user) { create(:user) }
    let(:bank_account) { create(:ach_account_stripe_succeed, user:) }
    let(:merchant_account) { create(:merchant_account_stripe_canada, user:) }

    before do
      user
      bank_account
      merchant_account
      bank_account.reload
      user.reload
    end

    let(:balance_1) { create(:balance, user:, date: Date.today - 1, currency: Currency::USD, amount_cents: 10_00, holding_currency: Currency::USD, holding_amount_cents: 10_00) }
    let(:balance_2) { create(:balance, user:, date: Date.today - 2, currency: Currency::USD, amount_cents: 20_00, holding_currency: Currency::CAD, holding_amount_cents: 20_00) }
    let(:payment) do
      payment = create(:payment, user:, currency: nil, amount_cents: nil)
      payment.balances << balance_1
      payment.balances << balance_2
      payment
    end

    before do
      described_class.prepare_payment_and_set_amount(payment, [balance_1, balance_2])
    end

    it "sets the currency" do
      expect(payment.currency).to eq(Currency::CAD)
    end

    it "sets the amount as the sum of the balances" do
      expect(payment.amount_cents).to eq(30_00)
    end
  end

  describe "prepare_payment_and_set_amount for Korean bank account" do
    let(:user) { create(:user) }
    let(:bank_account) { create(:korea_bank_account, user:) }
    let(:merchant_account) { create(:merchant_account_stripe_korea, user:) }

    before do
      user
      bank_account
      merchant_account
      bank_account.reload
      user.reload
    end

    let(:balance_1) { create(:balance, user:, date: Date.today - 1, currency: Currency::USD, amount_cents: 100_00, holding_currency: Currency::USD, holding_amount_cents: 100_00) }
    let(:balance_2) { create(:balance, user:, date: Date.today - 2, currency: Currency::USD, amount_cents: 200_00, holding_currency: Currency::USD, holding_amount_cents: 200_00) }
    let(:payment) do
      payment = create(:payment, user:, currency: nil, amount_cents: nil)
      payment.balances << balance_1
      payment.balances << balance_2
      payment
    end

    before do
      described_class.prepare_payment_and_set_amount(payment, [balance_1, balance_2])
    end

    it "sets the currency" do
      expect(payment.currency).to eq(Currency::KRW)
    end

    it "sets the amount as the sum of the balances, converted to match the database for KRW" do
      expect(payment.amount_cents).to eq(39640900)
    end
  end

  describe ".enqueue_payments" do
    let!(:yesterday) { Date.yesterday.to_s }
    let!(:user_ids) { [1, 2, 3, 4] }

    it "enqueues PayoutUsersWorker jobs for the supplied payments" do
      described_class.enqueue_payments(user_ids, yesterday)

      expect(PayoutUsersWorker.jobs.size).to eq(user_ids.size)
      sidekiq_job_args = user_ids.each_with_object([]) do |user_id, accumulator|
        accumulator << [yesterday, PayoutProcessorType::STRIPE, user_id]
      end
      expect(PayoutUsersWorker.jobs.map { _1["args"] }).to match_array(sidekiq_job_args)
    end
  end

  describe ".process_payments" do
    let(:payment1) { create(:payment) }
    let(:payment2) { create(:payment) }
    let(:payment3) { create(:payment) }
    let(:payments) { [payment1, payment2, payment3] }

    it "calls `perform_payment` for every payment" do
      allow(described_class).to receive(:perform_payment).with(anything)

      expect(described_class).to receive(:perform_payment).with(payment1)
      expect(described_class).to receive(:perform_payment).with(payment2)
      expect(described_class).to receive(:perform_payment).with(payment3)

      described_class.process_payments(payments)
    end
  end

  describe "perform_payment" do
    let(:user) { create(:user) }
    let(:tos_agreement) { create(:tos_agreement, user:) }
    let(:user_compliance_info) { create(:user_compliance_info, user:) }
    let(:bank_account) { create(:ach_account_stripe_succeed, user:) }

    before do
      tos_agreement
      user_compliance_info
      bank_account
    end

    let(:merchant_account) { create(:merchant_account_stripe, user: user.reload) }

    before do
      merchant_account
      bank_account.reload
      user.reload
    end

    let(:payment_amount_cents) { 600_00 }
    let(:balances) do
      [
        create(:balance, state: "processing", merchant_account:, amount_cents: 100_00),
        create(:balance, state: "processing", merchant_account:, amount_cents: 200_00),
        create(:balance, state: "processing", merchant_account:, amount_cents: 300_00)
      ]
    end
    let(:payment) do
      create(:payment,
             user:, bank_account: bank_account.reload, state: "processing", processor: PayoutProcessorType::STRIPE,
             amount_cents: payment_amount_cents, payout_period_end_date: Date.today - 1, correlation_id: nil,
             balances:, payout_type: Payouts::PAYOUT_TYPE_STANDARD)
    end

    before do
      payment_intent = create_stripe_payment_intent(StripePaymentMethodHelper.success_available_balance.to_stripejs_payment_method_id,
                                                    amount: 600_00,
                                                    currency: "usd",
                                                    transfer_data: { destination: merchant_account.charge_processor_merchant_id })
      payment_intent.confirm
      Stripe::Charge.retrieve(id: payment_intent.latest_charge)
    end

    it "creates a transfer at stripe" do
      expect(Stripe::Payout).to receive(:create).with(
        {
          amount: payment_amount_cents,
          currency: "usd",
          destination: bank_account.stripe_bank_account_id,
          description: payment.external_id,
          statement_descriptor: "Gumroad",
          method: Payouts::PAYOUT_TYPE_STANDARD,
          metadata: {
            payment: payment.external_id,
            "balances{0}" => balances.map(&:external_id).join(","),
            bank_account: bank_account.external_id
          }
        },
        { stripe_account: merchant_account.charge_processor_merchant_id }
      ).and_call_original
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
    end

    it "marks the payment as processing" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      described_class.perform_payment(payment)
      expect(payment.state).to eq("processing")
    end

    it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
    end

    it "stores the stripe transfer's identifier on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_transfer_id).to match(/po_[a-zA-Z0-9]+/)
    end

    it "does not store an internal stripe transfer's identifier on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_internal_transfer_id).to eq(nil)
    end

    describe "the payment includes funds not held by stripe, which don't sum to a positive amount" do
      let(:balances_held_by_gumroad) do
        [
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: -5_00),
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: -5_00)
        ]
      end
      before do
        payment.balances += balances_held_by_gumroad
      end

      it "creates a normal transfer" do
        expect(Stripe::Payout).to receive(:create).with(
          {
            amount: payment_amount_cents,
            currency: "usd",
            destination: bank_account.stripe_bank_account_id,
            description: payment.external_id,
            statement_descriptor: "Gumroad",
            method: Payouts::PAYOUT_TYPE_STANDARD,
            metadata: {
              payment: payment.external_id,
              "balances{0}" => payment.balances.map(&:external_id).join(","),
              bank_account: bank_account.external_id
            }
          },
          { stripe_account: merchant_account.charge_processor_merchant_id }
        ).and_call_original
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
      end

      it "marks the payment as processing" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        described_class.perform_payment(payment)
        expect(payment.state).to eq("processing")
      end

      it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "stores the stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_transfer_id).to match(/po_[a-zA-Z0-9]+/)
      end

      it "stores the internal stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_internal_transfer_id).to eq(nil)
      end

      describe "the external transfer fails" do
        before do
          allow(Stripe::Payout).to receive(:create).and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
        end

        it "notifies bugsnag" do
          expect(Bugsnag).to receive(:notify)
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
        end

        it "returns the errors" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          errors = described_class.perform_payment(payment)
          expect(errors).to be_present
        end

        it "marks the payment as failed" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
          payment.reload
          expect(payment.state).to eq("failed")
        end
      end

      describe "the external transfer fails because the account cannot be paid" do
        before do
          allow(Stripe::Payout).to receive(:create).and_raise(Stripe::InvalidRequestError.new("Cannot create live transfers: The account has fields needed.", "amount_cents"))
        end

        it "returns the errors" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          errors = described_class.perform_payment(payment)
          expect(errors).to be_present
        end

        it "marks the payment as failed" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
          payment.reload
          expect(payment.state).to eq("failed")
        end

        it "marks the payment with a failure reason of cannot pay" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
          payment.reload
          expect(payment.failure_reason).to eq(Payment::FailureReason::CANNOT_PAY)
        end
      end

      describe "the external transfer fails because of an unsupported reason" do
        before do
          allow(Stripe::Payout).to receive(:create).and_raise(Stripe::InvalidRequestError.new("Food was not tasty.", "food_bad"))
        end

        it "notifies bugsnag" do
          expect(Bugsnag).to receive(:notify)
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
        end
      end
    end

    describe "the payment includes funds not held by stripe, which sum to a positive amount" do
      let(:balances_held_by_gumroad) do
        [
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 1_00),
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 1_00)
        ]
      end
      before do
        payment.balances += balances_held_by_gumroad
      end

      it "creates an internal transfer and a normal transfer" do
        expect(Stripe::Transfer).to receive(:create).once.with(
          hash_including(
            amount: balances_held_by_gumroad.sum(&:amount_cents),
            currency: "usd",
            destination: merchant_account.charge_processor_merchant_id,
            description: "Funds held by Gumroad for Payment #{payment.external_id}.",
            metadata: {
              payment: payment.external_id,
              "balances{0}" => balances_held_by_gumroad.map(&:external_id).join(",")
            }
          )
        ).and_call_original
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        expect(Stripe::Payout).to receive(:create).once.with(
          hash_including(
            amount: payment.amount_cents,
            currency: payment.currency,
            destination: bank_account.stripe_bank_account_id,
            description: payment.external_id,
            statement_descriptor: "Gumroad",
            method: Payouts::PAYOUT_TYPE_STANDARD,
            metadata: {
              payment: payment.external_id,
              "balances{0}" => payment.balances.map(&:external_id).join(","),
              bank_account: bank_account.external_id
            }
          ),
          { stripe_account: merchant_account.charge_processor_merchant_id }
        ).and_call_original
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
      end

      it "marks the payment as processing" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        described_class.perform_payment(payment)
        expect(payment.state).to eq("processing")
      end

      it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "stores the stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_transfer_id).to match(/po_[a-zA-Z0-9]+/)
      end

      it "stores the internal stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_internal_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
      end

      describe "the internal transfer fails" do
        before do
          allow(Stripe::Transfer).to receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
        end

        it "notifies bugsnag" do
          expect(Bugsnag).to receive(:notify)
          errors = described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          expect(errors).to be_present
        end

        it "returns the errors" do
          errors = described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          expect(errors).to be_present
        end

        it "marks the payment as failed" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          payment.reload
          expect(payment.state).to eq("failed")
        end
      end

      describe "the external transfer fails" do
        describe "mocked" do
          let(:internal_transfer) do
            transfer = double
            allow(transfer).to receive(:id).and_return("tr_1234")
            allow(transfer).to receive(:destination_payment).and_return("py_1234")
            transfer
          end

          let(:destination_payment) do
            destination_payment_balance_transaction = double
            allow(destination_payment_balance_transaction).to receive(:amount).and_return(50_00)
            destination_payment = double
            allow(destination_payment).to receive(:balance_transaction).and_return(destination_payment_balance_transaction)
            destination_payment
          end

          before do
            expect(Stripe::Transfer).to(receive(:create).once.and_return(internal_transfer))
            expect(Stripe::Charge).to(receive(:retrieve).and_return(destination_payment))
            expect(Stripe::Payout).to(receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents")))
            expect(Stripe::Transfer).to(receive(:retrieve).with(internal_transfer.id).and_return(internal_transfer))
            expect(described_class).to receive(:create_credit_for_difference_from_reversed_internal_transfer)
          end

          it "creates a reversal for the internal transfer" do
            expect(internal_transfer).to receive_message_chain(:reversals, :create)
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            described_class.perform_payment(payment)
          end
        end

        describe "hitting stripe" do
          before do
            expect(Stripe::Transfer).to(receive(:create).once.and_call_original)
            expect(Stripe::Payout).to(receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents")))
          end

          it "notifies bugsnag" do
            expect(Bugsnag).to receive(:notify)
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            described_class.perform_payment(payment)
          end

          it "returns the errors" do
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            errors = described_class.perform_payment(payment)
            expect(errors).to be_present
          end

          it "marks the payment as failed" do
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            described_class.perform_payment(payment)
            payment.reload
            expect(payment.state).to eq("failed")
          end
        end
      end
    end

    describe "transfer fails due to an invalid request (amount over balance of creator)" do
      it "returns an error" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        payment.amount_cents = 500_000 # adjust payment amount to be over what's in the account
        errors = described_class.perform_payment(payment)
        expect(errors).to be_present
        expect(errors.first).to match(/You have insufficient funds in your Stripe account for this transfer/)
      end
    end
  end

  describe "perform_payment for a US account with instant payout method type" do
    let(:user) { create(:user) }
    let(:tos_agreement) { create(:tos_agreement, user:) }
    let(:user_compliance_info) { create(:user_compliance_info, user:) }
    let(:bank_account) { create(:ach_account_stripe_succeed, user:) }

    before do
      tos_agreement
      user_compliance_info
      bank_account
    end

    let(:merchant_account) { create(:merchant_account_stripe, user: user.reload) }

    before do
      merchant_account
      bank_account.reload
      user.reload
    end

    let(:payment_amount_cents) { 600_00 }
    let(:balances) do
      [
        create(:balance, state: "processing", merchant_account:, amount_cents: 100_00),
        create(:balance, state: "processing", merchant_account:, amount_cents: 200_00),
        create(:balance, state: "processing", merchant_account:, amount_cents: 300_00)
      ]
    end
    let(:payment) do
      create(:payment,
             user:, bank_account: bank_account.reload, state: "processing", processor: PayoutProcessorType::STRIPE,
             amount_cents: payment_amount_cents, payout_period_end_date: Date.today - 1, correlation_id: nil,
             balances:, payout_type: Payouts::PAYOUT_TYPE_INSTANT)
    end

    before do
      payment_intent = create_stripe_payment_intent(StripePaymentMethodHelper.success_available_balance.to_stripejs_payment_method_id,
                                                    amount: 600_00,
                                                    currency: "usd",
                                                    transfer_data: { destination: merchant_account.charge_processor_merchant_id })
      payment_intent.confirm
      Stripe::Charge.retrieve(id: payment_intent.latest_charge)
    end

    it "creates a transfer at stripe" do
      expect(Stripe::Payout).to receive(:create).with(
        {
          amount: (payment_amount_cents * 100 / (100 + StripePayoutProcessor::INSTANT_PAYOUT_FEE_PERCENT)).floor,
          currency: "usd",
          destination: bank_account.stripe_bank_account_id,
          description: payment.external_id,
          statement_descriptor: "Gumroad",
          method: Payouts::PAYOUT_TYPE_INSTANT,
          metadata: {
            payment: payment.external_id,
            "balances{0}" => balances.map(&:external_id).join(","),
            bank_account: bank_account.external_id
          }
        },
        { stripe_account: merchant_account.charge_processor_merchant_id }
      ).and_call_original
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
    end

    it "marks the payment as processing" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      described_class.perform_payment(payment)
      expect(payment.state).to eq("processing")
    end

    it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
    end

    it "stores the stripe transfer's identifier on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_transfer_id).to match(/po_[a-zA-Z0-9]+/)
    end

    it "does not store an internal stripe transfer's identifier on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_internal_transfer_id).to eq(nil)
    end

    describe "the payment includes funds not held by stripe, which don't sum to a positive amount" do
      let(:balances_held_by_gumroad) do
        [
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: -5_00),
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: -5_00)
        ]
      end
      before do
        payment.balances += balances_held_by_gumroad
      end

      it "creates a normal transfer" do
        expect(Stripe::Payout).to receive(:create).with(
          {
            amount: (payment_amount_cents * 100 / (100 + StripePayoutProcessor::INSTANT_PAYOUT_FEE_PERCENT)).floor,
            currency: "usd",
            destination: bank_account.stripe_bank_account_id,
            description: payment.external_id,
            statement_descriptor: "Gumroad",
            method: Payouts::PAYOUT_TYPE_INSTANT,
            metadata: {
              payment: payment.external_id,
              "balances{0}" => payment.balances.map(&:external_id).join(","),
              bank_account: bank_account.external_id
            }
          },
          { stripe_account: merchant_account.charge_processor_merchant_id }
        ).and_call_original
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
      end

      it "marks the payment as processing" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        described_class.perform_payment(payment)
        expect(payment.state).to eq("processing")
      end

      it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "stores the stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_transfer_id).to match(/po_[a-zA-Z0-9]+/)
      end

      it "stores the internal stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_internal_transfer_id).to eq(nil)
      end

      describe "the external transfer fails" do
        before do
          allow(Stripe::Payout).to receive(:create).and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
        end

        it "notifies bugsnag" do
          expect(Bugsnag).to receive(:notify)
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
        end

        it "returns the errors" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          errors = described_class.perform_payment(payment)
          expect(errors).to be_present
        end

        it "marks the payment as failed" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
          payment.reload
          expect(payment.state).to eq("failed")
        end
      end

      describe "the external transfer fails because the account cannot be paid" do
        before do
          allow(Stripe::Payout).to receive(:create).and_raise(Stripe::InvalidRequestError.new("Cannot create live transfers: The account has fields needed.", "amount_cents"))
        end

        it "returns the errors" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          errors = described_class.perform_payment(payment)
          expect(errors).to be_present
        end

        it "marks the payment as failed" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
          payment.reload
          expect(payment.state).to eq("failed")
        end

        it "marks the payment with a failure reason of cannot pay" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
          payment.reload
          expect(payment.failure_reason).to eq(Payment::FailureReason::CANNOT_PAY)
        end
      end

      describe "the external transfer fails because of an unsupported reason" do
        before do
          allow(Stripe::Payout).to receive(:create).and_raise(Stripe::InvalidRequestError.new("Food was not tasty.", "food_bad"))
        end

        it "notifies bugsnag" do
          expect(Bugsnag).to receive(:notify)
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
        end
      end
    end

    describe "the payment includes funds not held by stripe, which sum to a positive amount" do
      let(:balances_held_by_gumroad) do
        [
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 1_00),
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 1_00)
        ]
      end
      before do
        payment.balances += balances_held_by_gumroad
      end

      it "creates an internal transfer and a normal transfer" do
        expect(Stripe::Transfer).to receive(:create).once.with(
          hash_including(
            amount: balances_held_by_gumroad.sum(&:amount_cents),
            currency: "usd",
            destination: merchant_account.charge_processor_merchant_id,
            description: "Funds held by Gumroad for Payment #{payment.external_id}.",
            metadata: {
              payment: payment.external_id,
              "balances{0}" => balances_held_by_gumroad.map(&:external_id).join(",")
            }
          )
        ).and_call_original
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        expect(Stripe::Payout).to receive(:create).once.with(
          hash_including(
            amount: payment.amount_cents,
            currency: payment.currency,
            destination: bank_account.stripe_bank_account_id,
            description: payment.external_id,
            statement_descriptor: "Gumroad",
            method: Payouts::PAYOUT_TYPE_INSTANT,
            metadata: {
              payment: payment.external_id,
              "balances{0}" => payment.balances.map(&:external_id).join(","),
              bank_account: bank_account.external_id
            }
          ),
          { stripe_account: merchant_account.charge_processor_merchant_id }
        ).and_call_original
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
      end

      it "marks the payment as processing" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        described_class.perform_payment(payment)
        expect(payment.state).to eq("processing")
      end

      it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "stores the stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_transfer_id).to match(/po_[a-zA-Z0-9]+/)
      end

      it "stores the internal stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_internal_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
      end

      describe "the internal transfer fails" do
        before do
          allow(Stripe::Transfer).to receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
        end

        it "notifies bugsnag" do
          expect(Bugsnag).to receive(:notify)
          errors = described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          expect(errors).to be_present
        end

        it "returns the errors" do
          errors = described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          expect(errors).to be_present
        end

        it "marks the payment as failed" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          payment.reload
          expect(payment.state).to eq("failed")
        end
      end

      describe "the external transfer fails" do
        describe "mocked" do
          let(:internal_transfer) do
            transfer = double
            allow(transfer).to receive(:id).and_return("tr_1234")
            allow(transfer).to receive(:destination_payment).and_return("py_1234")
            transfer
          end

          let(:destination_payment) do
            destination_payment_balance_transaction = double
            allow(destination_payment_balance_transaction).to receive(:amount).and_return(50_00)
            destination_payment = double
            allow(destination_payment).to receive(:balance_transaction).and_return(destination_payment_balance_transaction)
            destination_payment
          end

          before do
            expect(Stripe::Transfer).to(receive(:create).once.and_return(internal_transfer))
            expect(Stripe::Charge).to(receive(:retrieve).and_return(destination_payment))
            expect(Stripe::Payout).to(receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents")))
            expect(Stripe::Transfer).to(receive(:retrieve).with(internal_transfer.id).and_return(internal_transfer))
            expect(described_class).to receive(:create_credit_for_difference_from_reversed_internal_transfer)
          end

          it "creates a reversal for the internal transfer" do
            expect(internal_transfer).to receive_message_chain(:reversals, :create)
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            described_class.perform_payment(payment)
          end
        end

        describe "hitting stripe" do
          before do
            expect(Stripe::Transfer).to(receive(:create).once.and_call_original)
            expect(Stripe::Payout).to(receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents")))
          end

          it "notifies bugsnag" do
            expect(Bugsnag).to receive(:notify)
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            described_class.perform_payment(payment)
          end

          it "returns the errors" do
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            errors = described_class.perform_payment(payment)
            expect(errors).to be_present
          end

          it "marks the payment as failed" do
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            described_class.perform_payment(payment)
            payment.reload
            expect(payment.state).to eq("failed")
          end
        end
      end
    end

    describe "transfer fails due to an invalid request (amount over balance of creator)" do
      it "returns an error" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        payment.amount_cents = 500_000 # adjust payment amount to be over what's in the account
        errors = described_class.perform_payment(payment)
        expect(errors).to be_present
        expect(errors.first).to match(/You have insufficient funds in your Stripe account for this transfer/)
      end
    end
  end

  describe "perform_payment with a Canadian payout" do
    let(:user) { create(:user) }
    let(:tos_agreement) { create(:tos_agreement, user:) }
    let(:user_compliance_info) { create(:user_compliance_info, user:, zip_code: "M4C 1T2", state: "BC", country: "Canada") }
    let(:bank_account) { create(:ach_account_stripe_succeed, user:) }

    before do
      tos_agreement
      user_compliance_info
      bank_account
    end

    let(:merchant_account) do
      merchant_account = StripeMerchantAccountManager.create_account(user.reload, passphrase: "1234")
      merchant_account.currency = Currency::CAD
      merchant_account.save!
      merchant_account
    end

    before do
      merchant_account
      bank_account.reload
      user.reload
    end

    let(:payment_amount_cents) { 660_00 }
    let(:balances) do
      [
        create(:balance, state: "processing", merchant_account:, amount_cents: 100_00, holding_currency: Currency::CAD, holding_amount_cents: 110_00),
        create(:balance, state: "processing", merchant_account:, amount_cents: 200_00, holding_currency: Currency::CAD, holding_amount_cents: 220_00),
        create(:balance, state: "processing", merchant_account:, amount_cents: 300_00, holding_currency: Currency::CAD, holding_amount_cents: 330_00)
      ]
    end
    let(:payment) do
      create(:payment,
             user:, bank_account: bank_account.reload, state: "processing", processor: PayoutProcessorType::STRIPE,
             amount_cents: payment_amount_cents, payout_period_end_date: Date.today - 1, correlation_id: nil,
             balances:, payout_type: Payouts::PAYOUT_TYPE_STANDARD)
    end
    before do
      allow(Stripe::Payout).to receive(:create).and_return(double("id" => "tr_1234", "arrival_date" => 1732752000))
    end

    it "creates a transfer at stripe" do
      expect(Stripe::Payout).to receive(:create).with(
        {
          amount: payment_amount_cents,
          currency: "cad",
          destination: bank_account.stripe_bank_account_id,
          description: payment.external_id,
          statement_descriptor: "Gumroad",
          method: Payouts::PAYOUT_TYPE_STANDARD,
          metadata: {
            payment: payment.external_id,
            "balances{0}" => balances.map(&:external_id).join(","),
            bank_account: bank_account.external_id
          }
        },
        { stripe_account: merchant_account.charge_processor_merchant_id }
      ).and_return(double("id" => "tr_1234", "arrival_date" => 1732752000))
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
    end

    it "marks the payment as processing" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      described_class.perform_payment(payment)
      expect(payment.state).to eq("processing")
    end

    it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
    end

    it "stores the stripe transfer's identifier on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
    end

    it "stores the stripe payout's arrival date on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.arrival_date).to eq 1732752000
    end

    it "does not store an internal stripe transfer's identifier on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_internal_transfer_id).to eq(nil)
    end

    describe "the payment includes funds not held by stripe, which don't sum to a positive amount" do
      let(:balances_held_by_gumroad) do
        [
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: -5_00),
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: -5_00)
        ]
      end
      before do
        payment.balances += balances_held_by_gumroad
      end

      it "creates a normal transfer" do
        expect(Stripe::Payout).to receive(:create).with(
          {
            amount: payment_amount_cents,
            currency: "cad",
            destination: bank_account.stripe_bank_account_id,
            description: payment.external_id,
            statement_descriptor: "Gumroad",
            method: Payouts::PAYOUT_TYPE_STANDARD,
            metadata: {
              payment: payment.external_id,
              "balances{0}" => payment.balances.map(&:external_id).join(","),
              bank_account: bank_account.external_id
            }
          },
          { stripe_account: merchant_account.charge_processor_merchant_id }
        ).and_return(double("id" => "tr_1234", "arrival_date" => 1732752000))
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
      end

      it "marks the payment as processing" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        described_class.perform_payment(payment)
        expect(payment.state).to eq("processing")
      end

      it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "stores the stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
      end

      it "stores the internal stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_internal_transfer_id).to eq(nil)
      end

      describe "the external transfer fails" do
        before do
          allow(Stripe::Payout).to receive(:create).and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
        end

        it "notifies bugsnag" do
          expect(Bugsnag).to receive(:notify)
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
        end

        it "returns the errors" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          errors = described_class.perform_payment(payment)
          expect(errors).to be_present
        end

        it "marks the payment as failed" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
          payment.reload
          expect(payment.state).to eq("failed")
        end
      end
    end

    describe "the payment includes funds not held by stripe, which sum to a positive amount" do
      let(:balances_held_by_gumroad) do
        [
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 1_00),
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 1_00)
        ]
      end
      before do
        payment.balances += balances_held_by_gumroad
        allow(Stripe::Payout).to receive(:create).and_return(double("id" => "tr_1234", "destination_payment" => "py_1234", "arrival_date" => 1732752000))
        allow(Stripe::Charge).to receive(:retrieve).and_return(double("balance_transaction" => double("amount" => 3_00)))
      end

      it "creates an internal transfer and a normal transfer" do
        expect(Stripe::Transfer).to receive(:create).once.with(
          hash_including(
            amount: balances_held_by_gumroad.sum(&:amount_cents),
            currency: "usd",
            destination: merchant_account.charge_processor_merchant_id,
            description: "Funds held by Gumroad for Payment #{payment.external_id}.",
            metadata: {
              payment: payment.external_id,
              "balances{0}" => balances_held_by_gumroad.map(&:external_id).join(",")
            }
          )
        ).and_return(double("id" => "tr_1234", "destination_payment" => "py_1234", "arrival_date" => 1732752000))
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        expect(Stripe::Payout).to receive(:create).once.with(
          hash_including(
            amount: 663_00,
            currency: "cad",
            destination: bank_account.stripe_bank_account_id,
            description: payment.external_id,
            statement_descriptor: "Gumroad",
            method: Payouts::PAYOUT_TYPE_STANDARD,
            metadata: {
              payment: payment.external_id,
              "balances{0}" => payment.balances.map(&:external_id).join(","),
              bank_account: bank_account.external_id
            }
          ),
          { stripe_account: merchant_account.charge_processor_merchant_id }
        ).and_return(double("id" => "tr_1235", "arrival_date" => 1732752000))
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
      end

      it "marks the payment as processing" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        described_class.perform_payment(payment)
        expect(payment.state).to eq("processing")
      end

      it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "stores the stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
      end

      it "stores the internal stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_internal_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
      end

      describe "the internal transfer fails" do
        before do
          allow(Stripe::Transfer).to receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
        end

        it "notifies bugsnag" do
          expect(Bugsnag).to receive(:notify)
          errors = described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          expect(errors).to be_present
        end

        it "returns the errors" do
          errors = described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          expect(errors).to be_present
        end

        it "marks the payment as failed" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          payment.reload
          expect(payment.state).to eq("failed")
        end
      end

      describe "the external transfer fails" do
        describe "mocked" do
          let(:internal_transfer) do
            transfer = double
            allow(transfer).to receive(:id).and_return("tr_1234")
            allow(transfer).to receive(:destination_payment).and_return("py_1234")
            transfer
          end

          let(:destination_payment) do
            destination_payment_balance_transaction = double
            allow(destination_payment_balance_transaction).to receive(:amount).and_return(50_00)
            destination_payment = double
            allow(destination_payment).to receive(:balance_transaction).and_return(destination_payment_balance_transaction)
            destination_payment
          end

          before do
            expect(Stripe::Transfer).to(receive(:create).once.and_return(internal_transfer))
            expect(Stripe::Charge).to(receive(:retrieve).and_return(destination_payment))
            expect(Stripe::Payout).to(receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents")))
            expect(Stripe::Transfer).to(receive(:retrieve).with(internal_transfer.id).and_return(internal_transfer))
            allow(internal_transfer).to receive_message_chain(:reversals, :create)
            allow(described_class).to receive(:create_credit_for_difference_from_reversed_internal_transfer)
          end

          it "creates a reversal for the internal transfer" do
            expect(internal_transfer).to receive_message_chain(:reversals, :create)
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            described_class.perform_payment(payment)
          end

          it "creates a credit if necessary" do
            expect(described_class).to receive(:create_credit_for_difference_from_reversed_internal_transfer)
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            described_class.perform_payment(payment)
          end
        end

        describe "hitting stripe" do
          before do
            expect(Stripe::Transfer).to(receive(:create).once.and_call_original)
            expect(Stripe::Payout).to(receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents")))
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            allow(Stripe::Charge).to(receive(:retrieve).and_call_original)
          end

          it "notifies bugsnag" do
            expect(Bugsnag).to receive(:notify)
            described_class.perform_payment(payment)
          end

          it "returns the errors" do
            errors = described_class.perform_payment(payment)
            expect(errors).to be_present
          end

          it "marks the payment as failed" do
            described_class.perform_payment(payment)
            payment.reload
            expect(payment.state).to eq("failed")
          end

          describe "the reverse amount was the same as the original internal transfer" do
            it "does not create a credit for the difference" do
              described_class.perform_payment(payment)
              expect(Credit.last).to eq(nil)
            end
          end

          describe "the reverse amount was different for the managed account" do
            # Very hard to test
          end
        end
      end
    end
  end

  describe "perform_payment for a German merchant account" do
    let(:user) { create(:user) }
    let(:tos_agreement) { create(:tos_agreement, user:) }
    let(:user_compliance_info) { create(:user_compliance_info, user:, zip_code: "10115", country: "Germany") }
    let(:bank_account) { create(:european_bank_account, user:) }

    before do
      tos_agreement
      user_compliance_info
      bank_account
    end

    let(:merchant_account) do
      merchant_account = StripeMerchantAccountManager.create_account(user.reload, passphrase: "1234")
      merchant_account.currency = Currency::EUR
      merchant_account.save!
      merchant_account
    end

    before do
      merchant_account
      bank_account.reload
      user.reload
    end

    let(:payment_amount_cents) { 660_00 }
    let(:balances) do
      [
        create(:balance, state: "processing", merchant_account:, amount_cents: 100_00, holding_currency: Currency::EUR, holding_amount_cents: 110_00),
        create(:balance, state: "processing", merchant_account:, amount_cents: 200_00, holding_currency: Currency::EUR, holding_amount_cents: 220_00),
        create(:balance, state: "processing", merchant_account:, amount_cents: 300_00, holding_currency: Currency::EUR, holding_amount_cents: 330_00)
      ]
    end
    let(:payment) do
      create(:payment,
             user:, bank_account: bank_account.reload, state: "processing", processor: PayoutProcessorType::STRIPE,
             amount_cents: payment_amount_cents, payout_period_end_date: Date.today - 1, correlation_id: nil,
             balances:, payout_type: Payouts::PAYOUT_TYPE_STANDARD)
    end
    before do
      allow(Stripe::Payout).to receive(:create).and_return(double("id" => "tr_1234", "arrival_date" => 1732752000))
    end

    it "creates a transfer at stripe" do
      expect(Stripe::Payout).to receive(:create).with(
        {
          amount: payment_amount_cents,
          currency: "eur",
          destination: bank_account.stripe_bank_account_id,
          description: payment.external_id,
          statement_descriptor: "Gumroad",
          method: Payouts::PAYOUT_TYPE_STANDARD,
          metadata: {
            payment: payment.external_id,
            "balances{0}" => balances.map(&:external_id).join(","),
            bank_account: bank_account.external_id
          }
        },
        { stripe_account: merchant_account.charge_processor_merchant_id }
      ).and_return(double("id" => "tr_1234", "arrival_date" => 1732752000))
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
    end

    it "marks the payment as processing" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      described_class.perform_payment(payment)
      expect(payment.state).to eq("processing")
    end

    it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
    end

    it "stores the stripe transfer's identifier on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
    end

    it "does not store an internal stripe transfer's identifier on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_internal_transfer_id).to eq(nil)
    end

    describe "the payment includes funds not held by stripe, which don't sum to a positive amount" do
      let(:balances_held_by_gumroad) do
        [
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: -5_00),
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: -5_00)
        ]
      end
      before do
        payment.balances += balances_held_by_gumroad
      end

      it "creates a normal transfer" do
        expect(Stripe::Payout).to receive(:create).with(
          {
            amount: payment_amount_cents,
            currency: "eur",
            destination: bank_account.stripe_bank_account_id,
            description: payment.external_id,
            statement_descriptor: "Gumroad",
            method: Payouts::PAYOUT_TYPE_STANDARD,
            metadata: {
              payment: payment.external_id,
              "balances{0}" => payment.balances.map(&:external_id).join(","),
              bank_account: bank_account.external_id
            }
          },
          { stripe_account: merchant_account.charge_processor_merchant_id }
        ).and_return(double("id" => "tr_1234", "arrival_date" => 1732752000))
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
      end

      it "marks the payment as processing" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        described_class.perform_payment(payment)
        expect(payment.state).to eq("processing")
      end

      it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "stores the stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
      end

      it "stores the internal stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_internal_transfer_id).to eq(nil)
      end

      describe "the external transfer fails" do
        before do
          allow(Stripe::Payout).to receive(:create).and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
        end

        it "notifies bugsnag" do
          expect(Bugsnag).to receive(:notify)
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
        end

        it "returns the errors" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          errors = described_class.perform_payment(payment)
          expect(errors).to be_present
        end

        it "marks the payment as failed" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
          payment.reload
          expect(payment.state).to eq("failed")
        end
      end
    end

    describe "the payment includes funds not held by stripe, which sum to a positive amount" do
      let(:balances_held_by_gumroad) do
        [
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 1_00),
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 1_00)
        ]
      end
      before do
        payment.balances += balances_held_by_gumroad
        allow(Stripe::Payout).to receive(:create).and_return(double("id" => "tr_1234", "destination_payment" => "py_1234", "arrival_date" => 1732752000))
        allow(Stripe::Charge).to receive(:retrieve).and_return(double("balance_transaction" => double("amount" => 3_00)))
      end

      it "creates an internal transfer and a normal transfer" do
        expect(Stripe::Transfer).to receive(:create).once.with(
          hash_including(
            amount: balances_held_by_gumroad.sum(&:amount_cents),
            currency: "usd",
            destination: merchant_account.charge_processor_merchant_id,
            description: "Funds held by Gumroad for Payment #{payment.external_id}.",
            metadata: {
              payment: payment.external_id,
              "balances{0}" => balances_held_by_gumroad.map(&:external_id).join(",")
            }
          )
        ).and_return(double("id" => "tr_1234", "destination_payment" => "py_1234", "arrival_date" => 1732752000))
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        expect(Stripe::Payout).to receive(:create).once.with(
          hash_including(
            amount: 663_00,
            currency: "eur",
            destination: bank_account.stripe_bank_account_id,
            description: payment.external_id,
            statement_descriptor: "Gumroad",
            method: Payouts::PAYOUT_TYPE_STANDARD,
            metadata: {
              payment: payment.external_id,
              "balances{0}" => payment.balances.map(&:external_id).join(","),
              bank_account: bank_account.external_id
            }
          ),
          { stripe_account: merchant_account.charge_processor_merchant_id }
        ).and_return(double("id" => "tr_1235", "arrival_date" => 1732752000))
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
      end

      it "marks the payment as processing" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        described_class.perform_payment(payment)
        expect(payment.state).to eq("processing")
      end

      it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "stores the stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
      end

      it "stores the internal stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_internal_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
      end

      describe "the internal transfer fails" do
        before do
          allow(Stripe::Transfer).to receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
        end

        it "notifies bugsnag" do
          expect(Bugsnag).to receive(:notify)
          errors = described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          expect(errors).to be_present
        end

        it "returns the errors" do
          errors = described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          expect(errors).to be_present
        end

        it "marks the payment as failed" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          payment.reload
          expect(payment.state).to eq("failed")
        end
      end

      describe "the external transfer fails" do
        describe "mocked" do
          let(:internal_transfer) do
            transfer = double
            allow(transfer).to receive(:id).and_return("tr_1234")
            allow(transfer).to receive(:destination_payment).and_return("py_1234")
            transfer
          end

          let(:destination_payment) do
            destination_payment_balance_transaction = double
            allow(destination_payment_balance_transaction).to receive(:amount).and_return(50_00)
            destination_payment = double
            allow(destination_payment).to receive(:balance_transaction).and_return(destination_payment_balance_transaction)
            destination_payment
          end

          before do
            expect(Stripe::Transfer).to(receive(:create).once.and_return(internal_transfer))
            expect(Stripe::Charge).to(receive(:retrieve).and_return(destination_payment))
            expect(Stripe::Payout).to(receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents")))
            expect(Stripe::Transfer).to(receive(:retrieve).with(internal_transfer.id).and_return(internal_transfer))
            allow(internal_transfer).to receive_message_chain(:reversals, :create)
            allow(described_class).to receive(:create_credit_for_difference_from_reversed_internal_transfer)
          end

          it "creates a reversal for the internal transfer" do
            expect(internal_transfer).to receive_message_chain(:reversals, :create)
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            described_class.perform_payment(payment)
          end

          it "creates a credit if necessary" do
            expect(described_class).to receive(:create_credit_for_difference_from_reversed_internal_transfer)
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            described_class.perform_payment(payment)
          end
        end

        describe "hitting stripe" do
          before do
            expect(Stripe::Transfer).to(receive(:create).once.and_call_original)
            expect(Stripe::Payout).to(receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents")))
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            allow(Stripe::Charge).to(receive(:retrieve).and_call_original)
          end

          it "notifies bugsnag" do
            expect(Bugsnag).to receive(:notify)
            described_class.perform_payment(payment)
          end

          it "returns the errors" do
            errors = described_class.perform_payment(payment)
            expect(errors).to be_present
          end

          it "marks the payment as failed" do
            described_class.perform_payment(payment)
            payment.reload
            expect(payment.state).to eq("failed")
          end

          describe "the reverse amount was the same as the original internal transfer" do
            # Very hard to test
          end

          describe "the reverse amount was different for the managed account" do
            it "creates a credit for the difference" do
              described_class.perform_payment(payment)
              expect(Credit.last).not_to be_nil
            end
          end
        end
      end
    end
  end

  describe "perform_payment for a Singaporean merchant account" do
    let(:user) { create(:user) }
    let(:tos_agreement) { create(:tos_agreement, user:) }
    let(:user_compliance_info) { create(:user_compliance_info, user:, zip_code: "546080", country: "Singapore", nationality: "SG") }
    let(:bank_account) { create(:singaporean_bank_account, user:) }

    before do
      tos_agreement
      user_compliance_info
      bank_account
    end

    let(:merchant_account) do
      merchant_account = StripeMerchantAccountManager.create_account(user.reload, passphrase: "1234")
      merchant_account.currency = Currency::SGD
      merchant_account.save!
      merchant_account
    end

    before do
      merchant_account
      bank_account.reload
      user.reload
    end

    let(:payment_amount_cents) { 660_00 }
    let(:balances) do
      [
        create(:balance, state: "processing", merchant_account:, amount_cents: 100_00, holding_currency: Currency::SGD, holding_amount_cents: 110_00),
        create(:balance, state: "processing", merchant_account:, amount_cents: 200_00, holding_currency: Currency::SGD, holding_amount_cents: 220_00),
        create(:balance, state: "processing", merchant_account:, amount_cents: 300_00, holding_currency: Currency::SGD, holding_amount_cents: 330_00)
      ]
    end
    let(:payment) do
      create(:payment,
             user:, bank_account: bank_account.reload, state: "processing", processor: PayoutProcessorType::STRIPE,
             amount_cents: payment_amount_cents, payout_period_end_date: Date.today - 1, correlation_id: nil,
             balances:, payout_type: Payouts::PAYOUT_TYPE_STANDARD)
    end
    before do
      allow(Stripe::Payout).to receive(:create).and_return(double("id" => "tr_1234", "arrival_date" => 1732752000))
    end

    it "creates a transfer at stripe" do
      expect(Stripe::Payout).to receive(:create).with(
        {
          amount: payment_amount_cents,
          currency: "sgd",
          destination: bank_account.stripe_bank_account_id,
          description: payment.external_id,
          statement_descriptor: "Gumroad",
          method: Payouts::PAYOUT_TYPE_STANDARD,
          metadata: {
            payment: payment.external_id,
            "balances{0}" => balances.map(&:external_id).join(","),
            bank_account: bank_account.external_id
          }
        },
        { stripe_account: merchant_account.charge_processor_merchant_id }
      ).and_return(double("id" => "tr_1234", "arrival_date" => 1732752000))
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
    end

    it "marks the payment as processing" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      described_class.perform_payment(payment)
      expect(payment.state).to eq("processing")
    end

    it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
    end

    it "stores the stripe transfer's identifier on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
    end

    it "does not store an internal stripe transfer's identifier on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_internal_transfer_id).to eq(nil)
    end

    describe "the payment includes funds not held by stripe, which don't sum to a positive amount" do
      let(:balances_held_by_gumroad) do
        [
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: -5_00),
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: -5_00)
        ]
      end
      before do
        payment.balances += balances_held_by_gumroad
      end

      it "creates a normal transfer" do
        expect(Stripe::Payout).to receive(:create).with(
          {
            amount: payment_amount_cents,
            currency: "sgd",
            destination: bank_account.stripe_bank_account_id,
            description: payment.external_id,
            statement_descriptor: "Gumroad",
            method: Payouts::PAYOUT_TYPE_STANDARD,
            metadata: {
              payment: payment.external_id,
              "balances{0}" => payment.balances.map(&:external_id).join(","),
              bank_account: bank_account.external_id
            }
          },
          { stripe_account: merchant_account.charge_processor_merchant_id }
        ).and_return(double("id" => "tr_1234", "arrival_date" => 1732752000))
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
      end

      it "marks the payment as processing" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        described_class.perform_payment(payment)
        expect(payment.state).to eq("processing")
      end

      it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "stores the stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
      end

      it "stores the internal stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_internal_transfer_id).to eq(nil)
      end

      describe "the external transfer fails" do
        before do
          allow(Stripe::Payout).to receive(:create).and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
        end

        it "notifies bugsnag" do
          expect(Bugsnag).to receive(:notify)
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
        end

        it "returns the errors" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          errors = described_class.perform_payment(payment)
          expect(errors).to be_present
        end

        it "marks the payment as failed" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
          payment.reload
          expect(payment.state).to eq("failed")
        end
      end
    end

    describe "the payment includes funds not held by stripe, which sum to a positive amount" do
      let(:balances_held_by_gumroad) do
        [
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 1_00),
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 1_00)
        ]
      end
      before do
        payment.balances += balances_held_by_gumroad
        allow(Stripe::Payout).to receive(:create).and_return(double("id" => "tr_1234", "destination_payment" => "py_1234", "arrival_date" => 1732752000))
        allow(Stripe::Charge).to receive(:retrieve).and_return(double("balance_transaction" => double("amount" => 3_00)))
      end

      it "creates an internal transfer and a normal transfer" do
        expect(Stripe::Transfer).to receive(:create).once.with(
          hash_including(
            amount: balances_held_by_gumroad.sum(&:amount_cents),
            currency: "usd",
            destination: merchant_account.charge_processor_merchant_id,
            description: "Funds held by Gumroad for Payment #{payment.external_id}.",
            metadata: {
              payment: payment.external_id,
              "balances{0}" => balances_held_by_gumroad.map(&:external_id).join(",")
            }
          )
        ).and_return(double("id" => "tr_1234", "destination_payment" => "py_1234", "arrival_date" => 1732752000))
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        expect(Stripe::Payout).to receive(:create).once.with(
          hash_including(
            amount: 663_00,
            currency: "sgd",
            destination: bank_account.stripe_bank_account_id,
            description: payment.external_id,
            statement_descriptor: "Gumroad",
            method: Payouts::PAYOUT_TYPE_STANDARD,
            metadata: {
              payment: payment.external_id,
              "balances{0}" => payment.balances.map(&:external_id).join(","),
              bank_account: bank_account.external_id
            }
          ),
          { stripe_account: merchant_account.charge_processor_merchant_id }
        ).and_return(double("id" => "tr_1235", "arrival_date" => 1732752000))
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
      end

      it "marks the payment as processing" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        described_class.perform_payment(payment)
        expect(payment.state).to eq("processing")
      end

      it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "stores the stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
      end

      it "stores the internal stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_internal_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
      end

      describe "the internal transfer fails" do
        before do
          allow(Stripe::Transfer).to receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
        end

        it "notifies bugsnag" do
          expect(Bugsnag).to receive(:notify)
          errors = described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          expect(errors).to be_present
        end

        it "returns the errors" do
          errors = described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          expect(errors).to be_present
        end

        it "marks the payment as failed" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          payment.reload
          expect(payment.state).to eq("failed")
        end
      end

      describe "the external transfer fails" do
        describe "mocked" do
          let(:internal_transfer) do
            transfer = double
            allow(transfer).to receive(:id).and_return("tr_1234")
            allow(transfer).to receive(:destination_payment).and_return("py_1234")
            transfer
          end

          let(:destination_payment) do
            destination_payment_balance_transaction = double
            allow(destination_payment_balance_transaction).to receive(:amount).and_return(50_00)
            destination_payment = double
            allow(destination_payment).to receive(:balance_transaction).and_return(destination_payment_balance_transaction)
            destination_payment
          end

          before do
            expect(Stripe::Transfer).to(receive(:create).once.and_return(internal_transfer))
            expect(Stripe::Charge).to(receive(:retrieve).and_return(destination_payment))
            expect(Stripe::Payout).to(receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents")))
            expect(Stripe::Transfer).to(receive(:retrieve).with(internal_transfer.id).and_return(internal_transfer))
            allow(internal_transfer).to receive_message_chain(:reversals, :create)
            allow(described_class).to receive(:create_credit_for_difference_from_reversed_internal_transfer)
          end

          it "creates a reversal for the internal transfer" do
            expect(internal_transfer).to receive_message_chain(:reversals, :create)
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            described_class.perform_payment(payment)
          end

          it "creates a credit if necessary" do
            expect(described_class).to receive(:create_credit_for_difference_from_reversed_internal_transfer)
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            described_class.perform_payment(payment)
          end
        end

        describe "hitting stripe" do
          before do
            expect(Stripe::Transfer).to(receive(:create).once.and_call_original)
            expect(Stripe::Payout).to(receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents")))
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            allow(Stripe::Charge).to(receive(:retrieve).and_call_original)
          end

          it "notifies bugsnag" do
            expect(Bugsnag).to receive(:notify)
            described_class.perform_payment(payment)
          end

          it "returns the errors" do
            errors = described_class.perform_payment(payment)
            expect(errors).to be_present
          end

          it "marks the payment as failed" do
            described_class.perform_payment(payment)
            payment.reload
            expect(payment.state).to eq("failed")
          end

          describe "the reverse amount was the same as the original internal transfer" do
            # Very hard to test
          end

          describe "the reverse amount was different for the managed account" do
            it "creates a credit for the difference" do
              described_class.perform_payment(payment)
              expect(Credit.last).not_to be_nil
            end
          end
        end
      end
    end
  end

  describe "perform_payment for a Korean merchant account" do
    let(:user) { create(:user) }
    let(:tos_agreement) { create(:tos_agreement, user:) }
    let(:user_compliance_info) { create(:user_compliance_info, user:, zip_code: "546080", country: "Korea, Republic of") }
    let(:bank_account) { create(:korea_bank_account, user:) }

    before do
      tos_agreement
      user_compliance_info
      bank_account
    end

    let(:merchant_account) do
      merchant_account = StripeMerchantAccountManager.create_account(user.reload, passphrase: "1234")
      merchant_account.currency = Currency::KRW
      merchant_account.save!
      merchant_account
    end

    before do
      merchant_account
      bank_account.reload
      user.reload
    end

    let(:payment_amount_cents) { 660_00 }
    let(:balances) do
      [
        create(:balance, state: "processing", merchant_account:, amount_cents: 100_00, holding_currency: Currency::KRW, holding_amount_cents: 110_00),
        create(:balance, state: "processing", merchant_account:, amount_cents: 200_00, holding_currency: Currency::KRW, holding_amount_cents: 220_00),
        create(:balance, state: "processing", merchant_account:, amount_cents: 300_00, holding_currency: Currency::KRW, holding_amount_cents: 330_00)
      ]
    end
    let(:payment) do
      create(:payment,
             user:, bank_account: bank_account.reload, state: "processing", processor: PayoutProcessorType::STRIPE,
             amount_cents: payment_amount_cents, payout_period_end_date: Date.today - 1, correlation_id: nil,
             balances:, currency: Currency::KRW, payout_type: Payouts::PAYOUT_TYPE_STANDARD)
    end
    before do
      allow(Stripe::Payout).to receive(:create).and_return(double("id" => "tr_1234", "arrival_date" => 1732752000))
    end

    it "creates a transfer at stripe" do
      expect(Stripe::Payout).to receive(:create).with(
        {
          amount: payment_amount_cents,
          currency: "krw",
          destination: bank_account.stripe_bank_account_id,
          description: payment.external_id,
          statement_descriptor: "Gumroad",
          method: Payouts::PAYOUT_TYPE_STANDARD,
          metadata: {
            payment: payment.external_id,
            "balances{0}" => balances.map(&:external_id).join(","),
            bank_account: bank_account.external_id
          }
        },
        { stripe_account: merchant_account.charge_processor_merchant_id }
      ).and_return(double("id" => "tr_1234", "arrival_date" => 1732752000))
      described_class.prepare_payment_and_set_amount(payment, balances)
      expect(payment.amount_cents).to eq(payment_amount_cents * 100)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
    end

    it "marks the payment as processing" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      described_class.perform_payment(payment)
      expect(payment.state).to eq("processing")
    end

    it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
    end

    it "stores the stripe transfer's identifier on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
    end

    it "does not store an internal stripe transfer's identifier on the payment" do
      described_class.prepare_payment_and_set_amount(payment, balances)
      errors = described_class.perform_payment(payment)
      expect(errors).to be_empty
      expect(payment.stripe_internal_transfer_id).to eq(nil)
    end

    describe "the payment includes funds not held by stripe, which don't sum to a positive amount" do
      let(:balances_held_by_gumroad) do
        [
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: -5_00),
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: -5_00)
        ]
      end
      before do
        payment.balances += balances_held_by_gumroad
      end

      it "creates a normal transfer" do
        expect(Stripe::Payout).to receive(:create).with(
          {
            amount: payment_amount_cents,
            currency: "krw",
            destination: bank_account.stripe_bank_account_id,
            description: payment.external_id,
            statement_descriptor: "Gumroad",
            method: Payouts::PAYOUT_TYPE_STANDARD,
            metadata: {
              payment: payment.external_id,
              "balances{0}" => payment.balances.map(&:external_id).join(","),
              bank_account: bank_account.external_id
            }
          },
          { stripe_account: merchant_account.charge_processor_merchant_id }
        ).and_return(double("id" => "tr_1234", "arrival_date" => 1732752000))
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
      end

      it "marks the payment as processing" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        described_class.perform_payment(payment)
        expect(payment.state).to eq("processing")
      end

      it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "stores the stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
      end

      it "stores the internal stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_internal_transfer_id).to eq(nil)
      end

      describe "the external transfer fails" do
        before do
          allow(Stripe::Payout).to receive(:create).and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
        end

        it "notifies bugsnag" do
          expect(Bugsnag).to receive(:notify)
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
        end

        it "returns the errors" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          errors = described_class.perform_payment(payment)
          expect(errors).to be_present
        end

        it "marks the payment as failed" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          described_class.perform_payment(payment)
          payment.reload
          expect(payment.state).to eq("failed")
        end
      end
    end

    describe "the payment includes funds not held by stripe, which sum to a positive amount" do
      let(:balances_held_by_gumroad) do
        [
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 1_00),
          create(:balance, state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 1_00)
        ]
      end
      before do
        payment.balances += balances_held_by_gumroad
        allow(Stripe::Payout).to receive(:create).and_return(double("id" => "tr_1234", "destination_payment" => "py_1234", "arrival_date" => 1732752000))
        allow(Stripe::Charge).to receive(:retrieve).and_return(double("balance_transaction" => double("amount" => 3_00)))
      end

      it "creates an internal transfer and a normal transfer" do
        expect(Stripe::Transfer).to receive(:create).once.with(
          hash_including(
            amount: balances_held_by_gumroad.sum(&:amount_cents),
            currency: "usd",
            destination: merchant_account.charge_processor_merchant_id,
            description: "Funds held by Gumroad for Payment #{payment.external_id}.",
            metadata: {
              payment: payment.external_id,
              "balances{0}" => balances_held_by_gumroad.map(&:external_id).join(",")
            }
          )
        ).and_return(double("id" => "tr_1234", "destination_payment" => "py_1234", "arrival_date" => 1732752000))
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        expect(Stripe::Payout).to receive(:create).once.with(
          hash_including(
            amount: 663_00,
            currency: "krw",
            destination: bank_account.stripe_bank_account_id,
            description: payment.external_id,
            statement_descriptor: "Gumroad",
            method: Payouts::PAYOUT_TYPE_STANDARD,
            metadata: {
              payment: payment.external_id,
              "balances{0}" => payment.balances.map(&:external_id).join(","),
              bank_account: bank_account.external_id
            }
          ),
          { stripe_account: merchant_account.charge_processor_merchant_id }
        ).and_return(double("id" => "tr_1235", "arrival_date" => 1732752000))
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
      end

      it "marks the payment as processing" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        described_class.perform_payment(payment)
        expect(payment.state).to eq("processing")
      end

      it "stores the stripe account identifier of the account the transfer was created on, on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "stores the stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
      end

      it "stores the internal stripe transfer's identifier on the payment" do
        described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
        errors = described_class.perform_payment(payment)
        expect(errors).to be_empty
        expect(payment.stripe_internal_transfer_id).to match(/tr_[a-zA-Z0-9]+/)
      end

      describe "the internal transfer fails" do
        before do
          allow(Stripe::Transfer).to receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
        end

        it "notifies bugsnag" do
          expect(Bugsnag).to receive(:notify)
          errors = described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          expect(errors).to be_present
        end

        it "returns the errors" do
          errors = described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          expect(errors).to be_present
        end

        it "marks the payment as failed" do
          described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
          payment.reload
          expect(payment.state).to eq("failed")
        end
      end

      describe "the external transfer fails" do
        describe "mocked" do
          let(:internal_transfer) do
            transfer = double
            allow(transfer).to receive(:id).and_return("tr_1234")
            allow(transfer).to receive(:destination_payment).and_return("py_1234")
            transfer
          end

          let(:destination_payment) do
            destination_payment_balance_transaction = double
            allow(destination_payment_balance_transaction).to receive(:amount).and_return(50_00)
            destination_payment = double
            allow(destination_payment).to receive(:balance_transaction).and_return(destination_payment_balance_transaction)
            destination_payment
          end

          before do
            expect(Stripe::Transfer).to(receive(:create).once.and_return(internal_transfer))
            expect(Stripe::Charge).to(receive(:retrieve).and_return(destination_payment))
            expect(Stripe::Payout).to(receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents")))
            expect(Stripe::Transfer).to(receive(:retrieve).with(internal_transfer.id).and_return(internal_transfer))
            allow(internal_transfer).to receive_message_chain(:reversals, :create)
            allow(described_class).to receive(:create_credit_for_difference_from_reversed_internal_transfer)
          end

          it "creates a reversal for the internal transfer" do
            expect(internal_transfer).to receive_message_chain(:reversals, :create)
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            described_class.perform_payment(payment)
          end

          it "creates a credit if necessary" do
            expect(described_class).to receive(:create_credit_for_difference_from_reversed_internal_transfer)
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            described_class.perform_payment(payment)
          end
        end

        describe "hitting stripe" do
          before do
            expect(Stripe::Transfer).to(receive(:create).once.and_call_original)
            expect(Stripe::Payout).to(receive(:create).once.and_raise(Stripe::InvalidRequestError.new("Invalid request", "amount_cents")))
            described_class.prepare_payment_and_set_amount(payment, payment.balances.to_a)
            allow(Stripe::Charge).to(receive(:retrieve).and_call_original)
          end

          it "notifies bugsnag" do
            expect(Bugsnag).to receive(:notify)
            described_class.perform_payment(payment)
          end

          it "returns the errors" do
            errors = described_class.perform_payment(payment)
            expect(errors).to be_present
          end

          it "marks the payment as failed" do
            described_class.perform_payment(payment)
            payment.reload
            expect(payment.state).to eq("failed")
          end

          describe "the reverse amount was the same as the original internal transfer" do
            # Very hard to test
          end

          describe "the reverse amount was different for the managed account" do
            it "creates a credit for the difference" do
              described_class.perform_payment(payment)
              expect(Credit.last).not_to be_nil
            end
          end
        end
      end
    end
  end

  describe "handle_stripe_event" do
    let(:stripe_connect_account_id) { "acct_1234" }
    let(:stripe_event_id) { "evt_eventid" }
    let(:stripe_event_type) { raise "Define `stripe_event_type` in your `handle_stripe_event` test." }
    let(:stripe_event_object) { raise "Define `stripe_event_object` in your `handle_stripe_event` test." }
    let(:stripe_event) do
      {
        "id" => stripe_event_id,
        "created" => "1406748559", # "2014-07-30T19:29:19+00:00"
        "type" => stripe_event_type,
        "data" => {
          "object" => stripe_event_object.deep_stringify_keys
        }
      }
    end

    describe "payouts" do
      let(:stripe_transfer_id) { "tr_1234" }
      let(:payment_external_id) { nil }
      let(:stripe_event_object) do
        event_object = { object: "payout", id: stripe_transfer_id, currency: "usd", type: "bank_account", automatic: false }
        event_object[:metadata] = { payment: payment_external_id } if payment_external_id
        event_object.deep_stringify_keys
      end

      describe "an event we do nothing with, like payout.created" do
        let(:stripe_event_type) { "payout.created" }

        it "does not error or do anything interesting" do
          expect(Stripe::Payout).not_to receive(:retrieve)
          described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
        end
      end

      describe "an event about a manual payout on stripe standard connect account" do
        let(:stripe_event_type) { "payout.paid" }
        let(:stripe_event_object) { { object: "payout", id: "po_automatic", automatic: false, amount: 100 }.deep_stringify_keys }

        before do
          allow(Stripe::Payout).to receive(:retrieve).with("po_automatic", anything).and_return(stripe_event_object)
        end

        it "ignores the event and does not raise an error" do
          expect do
            described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
          end.not_to raise_error
        end
      end

      describe "an event about an automatic payout to bank account" do
        let(:stripe_event_type) { "payout.paid" }
        let(:stripe_event_object) { { object: "payout", id: "po_automatic", automatic: true, amount: 100, arrival_date: 1732752000 }.deep_stringify_keys }

        before do
          allow(Stripe::Payout).to receive(:retrieve).with("po_automatic", anything).and_return(stripe_event_object)
        end

        it "ignores the event and does not raise an error" do
          expect do
            described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
          end.not_to raise_error
        end
      end

      describe "an event about an automatic bank debit made by stripe", :sidekiq_inline do
        describe "payout.paid" do
          let!(:stripe_event) do
            {
              "id" => "evt_1MjvKyS3ZeAbEknFBhGaaSaO",
              "object" => "event",
              "account" => "acct_1Mid1dS3ZeAbEknF",
              "api_version" => Stripe.api_version,
              "created" => 1678413940,
              "data" => { "object" => { "id" => "po_1MjvG6S3ZeAbEknFg2elYwet", "object" => "payout", "amount" => -10000, "arrival_date" => 1678406400, "automatic" => true, "balance_transaction" => "txn_1MjvG6S3ZeAbEknFPvZRik6K", "created" => 1678413638, "currency" => "usd", "description" => "STRIPE PAYOUT", "destination" => "ba_1Mid1dS3ZeAbEknFLNPfy4rl", "failure_balance_transaction" => nil, "failure_code" => nil, "failure_message" => nil, "livemode" => false, "metadata" => {}, "method" => "standard", "original_payout" => nil, "reconciliation_status" => "in_progress", "reversed_by" => nil, "source_type" => "card", "statement_descriptor" => nil, "status" => "paid", "type" => "bank_account" } },
              "livemode" => false,
              "pending_webhooks" => 0,
              "request" => { "id" => nil, "idempotency_key" => nil },
              "type" => "payout.paid"
            }
          end

          let!(:stripe_payout) do
            {
              "id" => "po_1MjvG6S3ZeAbEknFg2elYwet",
              "object" => "payout",
              "amount" => -10000,
              "arrival_date" => 1678406400,
              "automatic" => true,
              "balance_transaction" => "txn_1MjvG6S3ZeAbEknFPvZRik6K",
              "created" => 1678413638,
              "currency" => "usd",
              "description" => "STRIPE PAYOUT",
              "destination" => "ba_1Mid1dS3ZeAbEknFLNPfy4rl",
              "failure_balance_transaction" => nil,
              "failure_code" => nil,
              "failure_message" => nil,
              "livemode" => false,
              "metadata" => {},
              "method" => "standard",
              "original_payout" => nil,
              "reconciliation_status" => "in_progress",
              "reversed_by" => nil,
              "source_type" => "card",
              "statement_descriptor" => nil,
              "status" => "paid",
              "type" => "bank_account"
            }
          end

          let!(:stripe_payout_with_balance_transaction) do
            {
              "id" => "po_1MjvG6S3ZeAbEknFg2elYwet",
              "object" => "payout",
              "amount" => -10000,
              "arrival_date" => 1678406400,
              "automatic" => true,
              "balance_transaction" => { "id" => "txn_1MjvG6S3ZeAbEknFPvZRik6K", "object" => "balance_transaction", "amount" => 10000, "available_on" => 1678413638, "created" => 1678413638, "currency" => "usd", "description" => "STRIPE PAYOUT", "exchange_rate" => nil, "fee" => 0, "fee_details" => [], "net" => 10000, "reporting_category" => "payout", "source" => "po_1MjvG6S3ZeAbEknFg2elYwet", "status" => "available", "type" => "payout" },
              "created" => 1678413638,
              "currency" => "usd",
              "description" => "STRIPE PAYOUT",
              "destination" => "ba_1Mid1dS3ZeAbEknFLNPfy4rl",
              "failure_balance_transaction" => nil,
              "failure_code" => nil,
              "failure_message" => nil,
              "livemode" => false,
              "metadata" => {},
              "method" => "standard",
              "original_payout" => nil,
              "reconciliation_status" => "in_progress",
              "reversed_by" => nil,
              "source_type" => "card",
              "statement_descriptor" => nil,
              "status" => "paid",
              "type" => "bank_account"
            }
          end

          let!(:stripe_event_id) { stripe_event["id"] }
          let!(:stripe_payout_id) { stripe_payout["id"] }
          let!(:stripe_connect_account_id) { stripe_event["account"] }
          let!(:amount_cents) { stripe_payout["amount"] }
          let!(:merchant_account) { create(:merchant_account, charge_processor_merchant_id: stripe_connect_account_id) }

          context "when payout is successful" do
            it "adds credit equal to debited amount to creator gumroad balance" do
              stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)

              expect(Credit).to(receive(:create_for_bank_debit_on_stripe_account!))
                  .with(amount_cents: amount_cents.abs, merchant_account:)
                  .and_call_original

              expect do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end.not_to raise_error

              credit = Credit.last
              expect(credit.merchant_account).to eq(merchant_account)
              expect(credit.user).to eq(merchant_account.user)
              expect(credit.amount_cents).to eq(-amount_cents)
            end
          end
        end
      end

      context "when event is about a payout we issued to a creator" do
        let!(:merchant_account) { create(:merchant_account, charge_processor_merchant_id: stripe_connect_account_id) }
        describe "payout.paid" do
          let(:stripe_event_type) { "payout.paid" }

          before do
            allow(Stripe::Payout).to receive(:retrieve).with(stripe_transfer_id, anything).and_return(stripe_event_object)
          end

          describe "payout doesn't match a payment" do
            it "raises an error" do
              expect do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end.to raise_error(RuntimeError)
            end
          end

          describe "payout partially matches a payment" do
            let(:payment) do
              create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                               stripe_connect_account_id:, stripe_transfer_id:, processor_fee_cents: 0)
            end
            let(:payment_external_id) { "asdfasdf" }

            before do
              payment
            end

            it "raises an error" do
              expect do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end.to raise_error(RuntimeError)
              payment.reload
              expect(payment.state).to eq("processing")
            end
          end

          describe "payout does match a payment" do
            let(:payment) do
              create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                               stripe_connect_account_id:, stripe_transfer_id:, processor_fee_cents: 0)
            end
            let(:payment_external_id) { payment.external_id }

            before do
              payment
            end

            it "marks the respective payment as complete" do
              described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              payment.reload
              expect(payment.state).to eq("completed")
            end

            describe "payment was already marked as failed" do
              before do
                payment.mark_failed!
              end

              it "does not change the state" do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                payment.reload
                expect(payment.state).to eq("failed")
              end
            end
          end
        end

        describe "payout.canceled" do
          let(:stripe_event_type) { "payout.canceled" }
          let(:stripe_event_object) do
            event_object = { object: "payout", id: stripe_transfer_id, currency: "usd", type: "bank_account", automatic: false }
            event_object[:metadata] = { payment: payment_external_id } if payment_external_id
            event_object.deep_stringify_keys
          end

          before do
            allow(Stripe::Payout).to receive(:retrieve).with(stripe_transfer_id, anything).and_return(stripe_event_object)
          end

          describe "payout doesn't match a payment" do
            it "raises an error" do
              expect do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end.to raise_error(RuntimeError)
            end
          end

          describe "payout partially matches a payment" do
            let!(:payment) do
              create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                               stripe_connect_account_id:, stripe_transfer_id:, processor_fee_cents: 0)
            end
            let(:payment_external_id) { "non-existent" }

            it "raises an error" do
              expect do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end.to raise_error(RuntimeError)
              payment.reload
              expect(payment.state).to eq("processing")
            end
          end

          describe "payout matches a payment" do
            let!(:payment) do
              payment = create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                                         stripe_connect_account_id:, stripe_transfer_id:, processor_fee_cents: 0)
              payment.balances << create(:balance, user: payment.user, state: :processing)
              payment
            end
            let(:payment_external_id) { payment.external_id }

            it "marks the respective payment as cancelled" do
              described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              payment.reload
              expect(payment.state).to eq("cancelled")
            end

            it "marks the respective balances as unpaid" do
              expect(payment.balances.first.state).to eq("processing")
              described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              payment.reload
              expect(payment.balances.first.state).to eq("unpaid")
            end

            context "when payment not in processing state" do
              before do
                payment.mark_completed!
              end

              it "raises an error" do
                expect do
                  described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                end.to raise_error(RuntimeError)
              end
            end

            context "when payment had an internal transfer" do
              let(:user) { create(:user) }
              let(:stripe_account_id) { "acct_1234" }
              let!(:merchant_account) do
                create(
                  :merchant_account,
                  user:,
                  charge_processor_id: StripeChargeProcessor.charge_processor_id,
                  charge_processor_merchant_id: stripe_account_id
                )
              end
              let(:stripe_internal_transfer_id) { "tr_5678" }
              let(:stripe_destination_payment_id) { "py_1234" }
              let(:stripe_refund_balance_transaction_id) { "txn_1Ects" }

              let(:amount_received_cents) { 100_00 }
              let(:amount_taken_cents) { 100_00 }

              let(:stripe_internal_transfer) do
                stripe_internal_transfer = double
                allow(stripe_internal_transfer).to receive_message_chain(:reversals, :create)
                allow(stripe_internal_transfer).to receive(:destination).and_return(stripe_account_id)
                allow(stripe_internal_transfer).to receive(:destination_payment).and_return(stripe_destination_payment_id)
                stripe_internal_transfer
              end

              let(:stripe_destination_payment) do
                destination_payment = double

                allow(stripe_internal_transfer).to receive(:destination).and_return(stripe_account_id)
                allow(destination_payment).to(receive_message_chain(:refunds, :first, :balance_transaction)
                                                  .and_return(stripe_refund_balance_transaction_id))
                allow(destination_payment).to receive_message_chain(:balance_transaction, :net) { amount_received_cents }

                destination_payment
              end

              let(:stripe_refund_balance_transaction) do
                stripe_refund_balance_transaction = double
                allow(stripe_refund_balance_transaction).to receive(:net) { -1 * amount_taken_cents }
                stripe_refund_balance_transaction
              end

              let(:payment) do
                create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing", user:,
                                 stripe_connect_account_id:, stripe_transfer_id:, processor_fee_cents: 0,
                                 stripe_internal_transfer_id:)
              end

              before do
                expect(Stripe::Transfer).to receive(:retrieve).with(stripe_internal_transfer_id).and_return(stripe_internal_transfer)
                expect(Stripe::Charge).to receive(:retrieve).with(hash_including(id: stripe_destination_payment_id), { stripe_account: stripe_account_id })
                                              .and_return(stripe_destination_payment)
                expect(Stripe::BalanceTransaction).to receive(:retrieve).with({ id: stripe_refund_balance_transaction_id }, { stripe_account: stripe_account_id })
                                                          .and_return(stripe_refund_balance_transaction)
              end

              it "reverses the internal transfer" do
                expect(stripe_internal_transfer).to receive_message_chain(:reversals, :create)
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end

              context "when the reverse amount was the same as the original internal transfer" do
                it "does not create a credit for the difference" do
                  described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                  expect(Credit.last).to eq(nil)
                end
              end

              context "when the reverse amount was different for the managed account" do
                let(:amount_taken_cents) { 105_00 }

                it "creates a credit for the difference" do
                  described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                  credit = Credit.last
                  expect(credit.returned_payment).to eq(payment)
                  expect(credit.amount_cents).to eq(0)
                  expect(credit.balance_transaction.holding_amount_gross_cents).to eq(-5_00)
                  expect(credit.balance_transaction.holding_amount_net_cents).to eq(-5_00)
                end

                it "changes the balance by the difference" do
                  described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                  user = payment.user.reload
                  # In this test the balance was zero, so we'll check if the balance is now the difference.
                  expect(user.balances.unpaid.sum(:holding_amount_cents)).to eq(-5_00)
                end
              end
            end
          end
        end

        describe "payout.failed" do
          let(:stripe_event_type) { "payout.failed" }
          let(:stripe_event_object) do
            event_object = { object: "payout", id: stripe_transfer_id, currency: "usd", type: "bank_account", failure_code: "account_closed", automatic: false }
            event_object[:metadata] = { payment: payment_external_id } if payment_external_id
            event_object.deep_stringify_keys
          end

          before do
            allow(Stripe::Payout).to receive(:retrieve).with(stripe_transfer_id, anything).and_return(stripe_event_object)
          end

          describe "payout doesn't match a payment" do
            it "raises an error" do
              expect do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end.to raise_error(RuntimeError)
            end
          end

          describe "payout partially matches a payment" do
            let(:payment) do
              create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                               stripe_connect_account_id:, stripe_transfer_id:, processor_fee_cents: 0)
            end
            let(:payment_external_id) { "asdfasdf" }

            before do
              payment
            end

            it "raises an error" do
              expect do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end.to raise_error(RuntimeError)
              payment.reload
              expect(payment.state).to eq("processing")
            end
          end

          describe "payout does match a payment" do
            let(:payment) do
              create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                               stripe_connect_account_id:, stripe_transfer_id:, processor_fee_cents: 0)
            end
            let(:payment_external_id) { payment.external_id }

            before do
              payment
            end

            it "marks the respective payment as failed" do
              described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              payment.reload
              expect(payment.state).to eq("failed")
            end

            it "saves the failure reason and notifies the user" do
              expect do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                payment.reload
              end.to have_enqueued_mail(ContactingCreatorMailer, :cannot_pay).with(payment.id)
              expect(payment.state).to eq("failed")
              expect(payment.failure_reason).to eq("account_closed")
            end

            describe "payment was already marked as completed" do
              before do
                payment.mark_completed!
              end

              it "sets the state to returned" do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                payment.reload
                expect(payment.state).to eq("returned")
              end
            end

            describe "had an internal transfer" do
              let(:user) { create(:user) }
              let(:stripe_account_id) { "acct_1234" }
              let(:merchant_account) do
                create(
                  :merchant_account,
                  user:,
                  charge_processor_id: StripeChargeProcessor.charge_processor_id,
                  charge_processor_merchant_id: stripe_account_id
                )
              end
              let(:stripe_internal_transfer_id) { "tr_5678" }
              let(:stripe_destination_payment_id) { "py_1234" }
              let(:stripe_refund_balance_transaction_id) { "txn_1Ects" }

              let(:amount_received_cents) { 100_00 }
              let(:amount_taken_cents) { 100_00 }

              let(:stripe_internal_transfer) do
                stripe_internal_transfer = double
                allow(stripe_internal_transfer).to receive_message_chain(:reversals, :create)
                allow(stripe_internal_transfer).to receive(:destination).and_return(stripe_account_id)
                allow(stripe_internal_transfer).to receive(:destination_payment).and_return(stripe_destination_payment_id)
                stripe_internal_transfer
              end

              let(:stripe_destination_payment) do
                destination_payment = double

                allow(stripe_internal_transfer).to receive(:destination).and_return(stripe_account_id)
                allow(destination_payment).to(receive_message_chain(:refunds, :first, :balance_transaction)
                  .and_return(stripe_refund_balance_transaction_id))
                allow(destination_payment).to receive_message_chain(:balance_transaction, :net) { amount_received_cents }

                destination_payment
              end

              let(:stripe_refund_balance_transaction) do
                stripe_refund_balance_transaction = double

                allow(stripe_refund_balance_transaction).to receive(:net) { -1 * amount_taken_cents }

                stripe_refund_balance_transaction
              end

              before do
                merchant_account
              end

              let(:payment) do
                create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing", user:,
                                 stripe_connect_account_id:, stripe_transfer_id:, processor_fee_cents: 0,
                                 stripe_internal_transfer_id:)
              end

              before do
                expect(Stripe::Transfer).to receive(:retrieve).with(stripe_internal_transfer_id).and_return(stripe_internal_transfer)
                expect(Stripe::Charge).to receive(:retrieve).with(hash_including(id: stripe_destination_payment_id), { stripe_account: stripe_account_id })
                                                            .and_return(stripe_destination_payment)
                expect(Stripe::BalanceTransaction).to receive(:retrieve).with({ id: stripe_refund_balance_transaction_id }, { stripe_account: stripe_account_id })
                                                                        .and_return(stripe_refund_balance_transaction)
              end

              it "reverses the internal transfer" do
                expect(stripe_internal_transfer).to receive_message_chain(:reversals, :create)
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end

              describe "the reverse amount was the same as the original internal transfer" do
                it "does not create a credit for the difference" do
                  described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                  expect(Credit.last).to eq(nil)
                end
              end

              describe "the reverse amount was different for the managed account" do
                let(:amount_taken_cents) { 105_00 }

                it "creates a credit for the difference" do
                  described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                  credit = Credit.last
                  expect(credit.returned_payment).to eq(payment)
                  expect(credit.amount_cents).to eq(0)
                  expect(credit.balance_transaction.holding_amount_gross_cents).to eq(-5_00)
                  expect(credit.balance_transaction.holding_amount_net_cents).to eq(-5_00)
                end

                it "has changed the balance by the difference" do
                  described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                  user = payment.user.reload
                  # In this test the balance was zero, so we'll check if the balance is now the difference.
                  expect(user.balances.unpaid.sum(:holding_amount_cents)).to eq(-5_00)
                end
              end

              describe "payment was already marked as completed" do
                before do
                  payment.mark_completed!
                end

                it "sets the state to returned" do
                  described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                  payment.reload
                  expect(payment.state).to eq("returned")
                end

                it "reverses the internal transfer" do
                  expect(stripe_internal_transfer).to receive_message_chain(:reversals, :create)
                  described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                end
              end
            end
          end
        end
      end

      context "when event is about a reversal of a payout we issued to a creator", :sidekiq_inline do
        let!(:merchant_account) { create(:merchant_account, charge_processor_merchant_id: stripe_connect_account_id) }
        let(:stripe_event_object) do
          {
            object: "payout",
            id: "reversal_payout_id",
            currency: "usd",
            failure_code: "account_closed",
            original_payout: stripe_transfer_id,
            automatic: false
          }
        end
        let(:original_stripe_payout) do
          {
            object: "payout",
            id: stripe_transfer_id,
            currency: "usd",
            failure_code: nil,
            automatic: false,
            metadata: {
              payment: metadata_payment_external_id
            }
          }.deep_stringify_keys
        end
        let(:metadata_payment_external_id) { nil }

        before do
          allow(Stripe::Payout).to receive(:retrieve).with(stripe_transfer_id, anything).and_return(original_stripe_payout)
        end

        describe "payout.paid" do
          let(:stripe_event_type) { "payout.paid" }
          let(:reversing_stripe_payout) do
            {
              object: "payout",
              id: "reversal_payout_id",
              currency: "usd",
              failure_code: nil,
              automatic: false,
              status: "paid",
              balance_transaction: {
                status: "available"
              }
            }.deep_stringify_keys
          end

          before do
            allow(Stripe::Payout).to receive(:retrieve).with(hash_including({ id: "reversal_payout_id" }), anything).and_return(reversing_stripe_payout)
          end

          context "when payout doesn't match a payment" do
            it "raises an error" do
              expect do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end.to raise_error(RuntimeError)
            end
          end

          context "when payout metadata doesn't match payment's ID" do
            let!(:payment) do
              create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing", processor_fee_cents: 0,
                               stripe_connect_account_id:, stripe_transfer_id:)
            end
            let(:metadata_payment_external_id) { "non-existent" }

            it "raises an error" do
              expect do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end.to raise_error(RuntimeError)
            end
          end

          context "when payout matches a payment" do
            let(:payment) do
              payment = create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing", processor_fee_cents: 0,
                                         stripe_connect_account_id:, stripe_transfer_id:)
              payment.balances << create(:balance, user: payment.user, state: :processing)
              payment
            end
            let(:metadata_payment_external_id) { payment.external_id }

            context "when payment is in processing state" do
              it "sets payment's state to failed" do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                payment.reload
                expect(payment.state).to eq("failed")
              end
            end

            context "when payment is in completed state" do
              it "sets payment's state to returned" do
                payment.update_attribute(:state, "completed")
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                payment.reload
                expect(payment.state).to eq("returned")
              end
            end

            it "marks payment's balances as unpaid" do
              expect(payment.balances.first.state).to eq("processing")
              described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              payment.reload
              expect(payment.balances.first.state).to eq("unpaid")
            end

            context "when payout had an internal transfer" do
              let(:stripe_account_id) { "acct_1234" }
              let(:stripe_internal_transfer_id) { "tr_5678" }
              let(:stripe_destination_payment_id) { "py_1234" }
              let(:stripe_refund_balance_transaction_id) { "txn_1Ects" }

              let!(:payment) do
                create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                                 stripe_connect_account_id:, stripe_transfer_id:,
                                 stripe_internal_transfer_id:, processor_fee_cents: 0)
              end

              let(:stripe_internal_transfer) do
                stripe_internal_transfer = double
                allow(stripe_internal_transfer).to receive_message_chain(:reversals, :create)
                allow(stripe_internal_transfer).to receive(:destination).and_return(stripe_account_id)
                allow(stripe_internal_transfer).to receive(:destination_payment).and_return(stripe_destination_payment_id)
                stripe_internal_transfer
              end

              let(:stripe_destination_payment) do
                destination_payment = double
                allow(stripe_internal_transfer).to receive(:destination).and_return(stripe_account_id)
                allow(destination_payment).to(receive_message_chain(:refunds, :first, :balance_transaction)
                                                  .and_return(stripe_refund_balance_transaction_id))
                allow(destination_payment).to receive_message_chain(:balance_transaction, :net) { 100_00 }
                destination_payment
              end

              let(:stripe_refund_balance_transaction) do
                stripe_refund_balance_transaction = double
                allow(stripe_refund_balance_transaction).to receive(:net) { -100_00 }
                stripe_refund_balance_transaction
              end

              before do
                allow(Stripe::Transfer).to receive(:retrieve).with(stripe_internal_transfer_id).and_return(stripe_internal_transfer)
                expect(Stripe::Charge).to receive(:retrieve).with(hash_including(id: stripe_destination_payment_id), { stripe_account: stripe_account_id })
                                              .and_return(stripe_destination_payment)
                allow(Stripe::BalanceTransaction).to receive(:retrieve).with({ id: stripe_refund_balance_transaction_id }, { stripe_account: stripe_account_id })
                                                         .and_return(stripe_refund_balance_transaction)
              end

              it "reverses the internal transfer" do
                expect(stripe_internal_transfer).to receive_message_chain(:reversals, :create)
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                payment.reload
                expect(payment.processor_reversing_payout_id).to eq("reversal_payout_id")
              end
            end
          end
        end

        describe "payout.canceled" do
          let(:stripe_event_type) { "payout.canceled" }

          context "when payout doesn't match a payment" do
            it "raises an error" do
              expect do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end.to raise_error(RuntimeError)
            end
          end

          context "when payout metadata doesn't match payment's ID" do
            let!(:payment) do
              create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing", processor_fee_cents: 0,
                               stripe_connect_account_id:, stripe_transfer_id:)
            end
            let(:metadata_payment_external_id) { "non-existent" }

            it "raises an error" do
              expect do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end.to raise_error(RuntimeError)
            end
          end

          context "when payout matches a payment" do
            let!(:payment) do
              create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing", processor_fee_cents: 0,
                               stripe_connect_account_id:, stripe_transfer_id:)
            end
            let(:metadata_payment_external_id) { payment.external_id }

            it "ignores the event - nothing to do, a manual reversal was canceled" do
              expect do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end.not_to raise_error
            end
          end
        end

        describe "payout.failed" do
          let(:stripe_event_type) { "payout.failed" }

          context "when payout doesn't match a payment" do
            it "raises an error" do
              expect do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end.to raise_error(RuntimeError)
            end
          end

          context "when payout metadata doesn't match payment's ID" do
            let!(:payment) do
              create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing", processor_fee_cents: 0,
                               stripe_connect_account_id:, stripe_transfer_id:)
            end
            let(:metadata_payment_external_id) { "non-existent" }

            it "raises an error" do
              expect do
                described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
              end.to raise_error(RuntimeError)
            end
          end

          context "when payout matches a payment" do
            let!(:payment) do
              create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing", processor_fee_cents: 0,
                               stripe_connect_account_id:, stripe_transfer_id:)
            end
            let(:metadata_payment_external_id) { payment.external_id }

            context "when payment has not been marked as reversed before" do
              it "ignores the event - nothing to do, a manual reversal did not succeed" do
                expect do
                  described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                end.not_to raise_error
              end
            end

            context "when payment has been marked as reversed before" do
              before do
                payment.processor_reversing_payout_id = "reversal_payout_id"
                payment.save!
              end

              it "notifies Bugsnag that a previously successful reversal has changed state to failed" do
                expect do
                  described_class.handle_stripe_event(stripe_event, stripe_connect_account_id:)
                end.to raise_error(RuntimeError, /The case needs manual review/)
              end
            end
          end
        end
      end
    end
  end

  describe ".instantly_payable_amount_cents_on_stripe" do
    let(:user) { create(:user) }
    let(:bank_account) { create(:ach_account, user:, stripe_bank_account_id: "ba_test") }

    before do
      user.bank_accounts = [bank_account]
    end

    context "when user has no active bank account" do
      before do
        user.bank_accounts = []
      end

      it "returns 0" do
        expect(described_class.instantly_payable_amount_cents_on_stripe(user)).to eq(0)
      end
    end

    context "when not eligible for instant payouts" do
      before do
        allow(Stripe::Balance).to receive(:retrieve).and_return(
          Stripe::Balance.construct_from(
            object: "balance"
          )
        )
      end

      it "returns 0" do
        expect(described_class.instantly_payable_amount_cents_on_stripe(user)).to eq(0)
      end
    end

    context "when eligible for instant payouts" do
      before do
        allow(Stripe::Balance).to receive(:retrieve).and_return(
          Stripe::Balance.construct_from(
            object: "balance",
            instant_available: [
              {
                amount: 123456,
                currency: "usd",
                net_available: [
                  {
                    amount: 123456,
                    destination: "ba_test",
                    source_types: { card: 123456 }
                  }
                ]
              }
            ]
          )
        )
      end

      it "returns the instant available amount" do
        expect(described_class.instantly_payable_amount_cents_on_stripe(user)).to eq(123456)
      end
    end

    context "when eligible but bank account doesn't match" do
      before do
        allow(Stripe::Balance).to receive(:retrieve).and_return(
          Stripe::Balance.construct_from(
            object: "balance",
            instant_available: [
              {
                amount: 123456,
                currency: "usd",
                net_available: [
                  {
                    amount: 123456,
                    destination: "ba_different",
                    source_types: { card: 123456 }
                  }
                ]
              }
            ]
          )
        )
      end

      it "returns 0" do
        expect(described_class.instantly_payable_amount_cents_on_stripe(user)).to eq(0)
      end
    end
  end
end
