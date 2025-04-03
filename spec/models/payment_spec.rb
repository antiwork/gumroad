# frozen_string_literal: true

require "spec_helper"

describe Payment do
  describe "mark" do
    it "sets the appropriate state" do
      payment = create(:payment)
      payment.mark("failed")
      expect(payment.reload.state).to eq "failed"

      payment = create(:payment)
      payment.mark("cancelled")
      expect(payment.reload.state).to eq "cancelled"

      payment = create(:payment)
      payment.mark("reversed")
      expect(payment.reload.state).to eq "reversed"

      payment = create(:payment)
      payment.mark("returned")
      expect(payment.reload.state).to eq "returned"

      payment = create(:payment)
      payment.mark("unclaimed")
      expect(payment.reload.state).to eq "unclaimed"

      payment = create(:payment)
      payment.txn_id = "something"
      payment.processor_fee_cents = 2
      payment.mark("completed")
      expect(payment.reload.state).to eq "completed"
    end

    it "raises an error on invalid state" do
      payment = create(:payment)
      expect do
        payment.mark("badstate")
      end.to raise_error(NoMethodError)
    end

    context "when the processor is PAYPAL" do
      it "allows a transition from processing to unclaimed" do
        payment = create(:payment, processor: PayoutProcessorType::PAYPAL)
        payment.mark("unclaimed")
        expect(payment.reload.state).to eq "unclaimed"
      end

      it "allows a transition from unclaimed to cancelled and marks balances as paid" do
        creator = create(:user)
        merchant_account = create(:merchant_account_paypal, user: creator)
        balance = create(:balance, user: creator, state: "processing", merchant_account:)
        payment = create(:payment_unclaimed, balances: [balance], processor: PayoutProcessorType::PAYPAL)
        payment.mark("cancelled")
        expect(payment.reload.state).to eq "cancelled"
        expect(balance.reload.state).to eq "unpaid"
      end
    end

    context "when the processor is STRIPE" do
      it "prevents a transition from processing to unclaimed" do
        payment = create(:payment, processor: PayoutProcessorType::STRIPE, stripe_connect_account_id: "acct_1234", stripe_transfer_id: "tr_1234")
        payment.mark("unclaimed")
        expect(payment.errors.full_messages.length).to eq(1)
        expect(payment.errors.full_messages.first).to eq("State cannot transition via \"mark unclaimed\"")
        expect(payment.reload.state).to eq "processing"
      end
    end

    describe "when transitioning to completed" do
      let(:payment) { create(:payment, processor: PayoutProcessorType::STRIPE, stripe_connect_account_id: "acct_1234", stripe_transfer_id: "tr_1234", processor_fee_cents: 100) }

      it "generates default abandoned cart workflow for the user" do
        expect(DefaultAbandonedCartWorkflowGeneratorService).to receive(:new).with(seller: payment.user).and_call_original
        expect_any_instance_of(DefaultAbandonedCartWorkflowGeneratorService).to receive(:generate)
        payment.mark_completed!
      end

      it "does not generate workflow if user is nil" do
        payment.user = nil
        expect(DefaultAbandonedCartWorkflowGeneratorService).not_to receive(:new)
        payment.mark_completed!
      end
    end
  end

  describe "send_cannot_pay_email" do
    let(:compliant_creator) { create(:user, user_risk_state: "compliant") }
    let(:payment) { create(:payment, state: "processing", processor: PayoutProcessorType::PAYPAL, processor_fee_cents: 0, user: compliant_creator) }

    it "sends the cannot pay email to the creator and sets the payout_date_of_last_payment_failure_email for user" do
      expect do
        payment.send_cannot_pay_email
      end.to have_enqueued_mail(ContactingCreatorMailer, :cannot_pay).with(payment.id)
      expect(compliant_creator.reload.payout_date_of_last_payment_failure_email.to_s).to eq(payment.payout_period_end_date.to_s)
    end

    it "does not send the cannot pay email if payout_date_of_last_payment_failure_email is same or newer than current payout date" do
      compliant_creator.payout_date_of_last_payment_failure_email = payment.payout_period_end_date
      compliant_creator.save!

      expect do
        payment.reload.send_cannot_pay_email
      end.to_not have_enqueued_mail(ContactingCreatorMailer, :cannot_pay).with(payment.id)

      expect(compliant_creator.reload.payout_date_of_last_payment_failure_email.to_s).to eq(payment.payout_period_end_date.to_s)
    end
  end

  describe "send_payout_failure_email" do
    let(:compliant_creator) { create(:user, user_risk_state: "compliant") }
    let(:payment) { create(:payment, state: "processing", processor: PayoutProcessorType::PAYPAL, processor_fee_cents: 0, failure_reason: "account_closed", user: compliant_creator) }

    it "sends the payout failure email to the creator and sets the payout_date_of_last_payment_failure_email for user" do
      expect do
        payment.send_payout_failure_email
      end.to have_enqueued_mail(ContactingCreatorMailer, :cannot_pay).with(payment.id)

      expect(compliant_creator.reload.payout_date_of_last_payment_failure_email.to_s).to eq(payment.payout_period_end_date.to_s)
    end

    it "does not send the payout failure email if failure_reason is cannot_pay" do
      payment.failure_reason = Payment::FailureReason::CANNOT_PAY
      payment.save!

      expect do
        payment.reload.send_payout_failure_email
      end.to_not have_enqueued_mail(ContactingCreatorMailer, :cannot_pay).with(payment.id)
    end
  end

  describe ".failed scope" do
    it "responds" do
      expect(Payment).to respond_to(:failed)
    end

    it "only returns failed payments" do
      create(:payment)
      create(:payment, state: :failed)
      expect(Payment.failed.length).to be(1)
      expect(Payment.failed.first.state).to eq("failed")
    end

    it "returns failed payments sorted descending by id" do
      failed_payments = (1..5).map { create(:payment, state: :failed) }
      sorted_ids = failed_payments.map(&:id).sort
      expect(Payment.failed.map(&:id)).to eq(sorted_ids.reverse)
    end
  end

  describe "emails" do
    describe "mark returned" do
      describe "if already completed" do
        let(:payment) { create(:payment, state: "completed", processor: PayoutProcessorType::ACH, processor_fee_cents: 0) }

        it "sends an email to the creator" do
          expect do
            payment.mark_returned!
          end.to have_enqueued_mail(ContactingCreatorMailer, :payment_returned).with(payment.id)
        end
      end

      describe "if not yet completed" do
        let(:payment) { create(:payment, state: "processing", processor: PayoutProcessorType::ACH, processor_fee_cents: 0) }

        it "does not send an email to the creator" do
          expect do
            payment.mark_returned!
          end.to_not have_enqueued_mail(ContactingCreatorMailer, :payment_returned).with(payment.id)
        end
      end
    end

    describe "mark failed with no reason" do
      let(:payment) { create(:payment, state: "processing", processor: PayoutProcessorType::ACH, processor_fee_cents: 0) }

      it "does not send an email to the creator" do
        expect do
          payment.mark_failed!
        end.to_not have_enqueued_mail(ContactingCreatorMailer, :cannot_pay).with(payment.id)
      end
    end

    describe "mark failed with reason cannot pay" do
      let(:creator) { create(:user) }
      let(:payment) { create(:payment, state: "processing", processor: PayoutProcessorType::ACH, processor_fee_cents: 0, user: creator) }

      it "sends an email to the creator" do
        creator.mark_compliant!(author_id: creator.id)
        expect do
          payment.mark_failed!(Payment::FailureReason::CANNOT_PAY)
        end.to have_enqueued_mail(ContactingCreatorMailer, :cannot_pay).with(payment.id)
      end
    end
  end

  describe "#humanized_failure_reason" do
    context "when the processor is STRIPE" do
      it "returns the value from failure_reason" do
        payment = create(:payment_failed, processor: "STRIPE", failure_reason: "cannot_pay")

        expect(payment.humanized_failure_reason).to eq("cannot_pay")
      end
    end

    context "when the processor is PAYPAL" do
      it "returns the full failure message" do
        payment = create(:payment_failed, processor: "PAYPAL", failure_reason: "PAYPAL 9302")

        expect(payment.humanized_failure_reason).to eq("PAYPAL 9302: Transaction was declined")
      end

      it "returns `nil` when the failure_reason value is absent" do
        payment = create(:payment_failed, processor: "PAYPAL", failure_reason: "")

        expect(payment.humanized_failure_reason).to eq(nil)
      end
    end
  end

  describe "#credit_amount_cents" do
    it "does not include credits created for refund fee retention" do
      creator = create(:user)
      balance = create(:balance, user: creator)
      purchase = create(:purchase, succeeded_at: 10.days.ago, link: create(:product, user: creator))
      refund = create(:refund, purchase:, fee_cents: 100)
      credit = create(:credit, user: creator, amount_cents: -100, fee_retention_refund: refund, balance:)
      payment = create(:payment, balances: [balance])

      expect(credit.fee_retention_refund).to eq(refund)
      expect(credit.balance).to eq(balance)
      expect(payment.credit_amount_cents).to eq(0)
    end
  end

  describe "#sync_with_payout_processor" do
    describe "when processor is PayPal" do
      before do
        @payment = create(:payment, processor: PayoutProcessorType::PAYPAL)
      end

      it "calls #sync_with_paypal if state is non-terminal" do
        %w(creating processing unclaimed completed failed cancelled returned reversed).each do |payment_state|
          if payment_state == "completed"
            @payment.txn_id = "12345"
            @payment.processor_fee_cents = 10
          end
          @payment.update!(state: payment_state)

          if Payment::NON_TERMINAL_STATES.include?(payment_state)
            expect_any_instance_of(Payment).to receive(:sync_with_paypal)
          else
            expect_any_instance_of(Payment).not_to receive(:sync_with_paypal)
          end

          @payment.sync_with_payout_processor
        end
      end
    end

    describe "when processor is Stripe" do
      before do
        @payment = create(:payment, processor: PayoutProcessorType::STRIPE, stripe_transfer_id: "12345", stripe_connect_account_id: "acct_12345")
      end

      it "does not call #sync_with_paypal for any payment state" do
        %w(creating processing unclaimed completed failed cancelled returned reversed).each do |payment_state|
          if payment_state == "completed"
            @payment.txn_id = "12345"
            @payment.processor_fee_cents = 10
          end
          @payment.update!(state: payment_state)

          expect_any_instance_of(Payment).not_to receive(:sync_with_paypal)

          @payment.sync_with_payout_processor
        end
      end
    end
  end

  describe "#sync_with_paypal" do
    describe "when the payout is not created in the split mode" do
      it "fetches and sets the new payment state, txn_id, correlation_id, and fee from PayPal" do
        payment = create(:payment, processor: PayoutProcessorType::PAYPAL, txn_id: "txn_12345", correlation_id: nil)

        expected_response = { state: "completed", transaction_id: "txn_12345", correlation_id: "correlation_id_12345", paypal_fee: "-1.15" }
        expect(PaypalPayoutProcessor).to(
          receive(:search_payment_on_paypal).with(amount_cents: payment.amount_cents, transaction_id: payment.txn_id,
                                                  payment_address: payment.payment_address,
                                                  start_date: payment.created_at.beginning_of_day - 1.day,
                                                  end_date: payment.created_at.end_of_day + 1.day).and_return(expected_response))

        expect do
          payment.send(:sync_with_paypal)
        end.to change { payment.reload.state }.from("processing").to("completed")
        expect(payment.txn_id).to eq("txn_12345")
        expect(payment.correlation_id).to eq("correlation_id_12345")
        expect(payment.processor_fee_cents).to eq(115)
      end

      it "marks the payment as failed if no corresponding txn is found on PayPal" do
        payment = create(:payment, processor_fee_cents: 10, txn_id: nil)

        expect(PaypalPayoutProcessor).to(
          receive(:search_payment_on_paypal).with(amount_cents: payment.amount_cents, transaction_id: payment.txn_id,
                                                  payment_address: payment.payment_address,
                                                  start_date: payment.created_at.beginning_of_day - 1.day,
                                                  end_date: payment.created_at.end_of_day + 1.day).and_return(nil))

        expect do
          expect do
            payment.send(:sync_with_paypal)
          end.to change { payment.reload.state }.from("processing").to("failed")
        end.to change { payment.reload.failure_reason }.from(nil).to("Transaction not found")
      end

      it "does not change the payment if multiple txns are found on PayPal" do
        payment = create(:payment, processor_fee_cents: 10, txn_id: nil, correlation_id: nil)

        expect(PaypalPayoutProcessor).to(
          receive(:search_payment_on_paypal).with(amount_cents: payment.amount_cents, transaction_id: payment.txn_id,
                                                  payment_address: payment.payment_address,
                                                  start_date: payment.created_at.beginning_of_day - 1.day,
                                                  end_date: payment.created_at.end_of_day + 1.day).and_raise(RuntimeError))

        expect do
          payment.send(:sync_with_paypal)
        end.not_to change { payment.reload.state }
      end
    end

    describe "when the payout is created in the split mode" do
      let(:payment) do
        # Payout was sent out
        payment = create(:payment, processor_fee_cents: 10)

        # IPN was received and one of the split parts was in the pending state
        payment.was_created_in_split_mode = true
        payment.split_payments_info = [
          { "unique_id" => "SPLIT_1-1", "state" => "completed", "correlation_id" => "fcf", "amount_cents" => 100, "errors" => [], "txn_id" => "02P" },
          { "unique_id" => "SPLIT_1-2", "state" => "pending", "correlation_id" => "6db", "amount_cents" => 50, "errors" => [], "txn_id" => "4LR" }
        ]
        payment.save!
        payment
      end

      it "fetches and sets the new payment status from PayPal for all split parts" do
        expect(PaypalPayoutProcessor).to(
          receive(:get_latest_payment_state_from_paypal).with(100,
                                                              "02P",
                                                              payment.created_at.beginning_of_day - 1.day,
                                                              "completed").and_return("completed"))

        expect(PaypalPayoutProcessor).to(
          receive(:get_latest_payment_state_from_paypal).with(50,
                                                              "4LR",
                                                              payment.created_at.beginning_of_day - 1.day,
                                                              "pending").and_return("completed"))

        expect(PaypalPayoutProcessor).to receive(:update_split_payment_state).and_call_original

        expect do
          payment.send(:sync_with_paypal)
        end.to change { payment.reload.state }.from("processing").to("completed")
      end

      it "adds an error if not all split parts statuses are same" do
        expect(PaypalPayoutProcessor).to(
          receive(:get_latest_payment_state_from_paypal).with(100,
                                                              "02P",
                                                              payment.created_at.beginning_of_day - 1.day,
                                                              "completed").and_return("completed"))

        expect(PaypalPayoutProcessor).to(
          receive(:get_latest_payment_state_from_paypal).with(50,
                                                              "4LR",
                                                              payment.created_at.beginning_of_day - 1.day,
                                                              "pending").and_return("pending"))

        expect(PaypalPayoutProcessor).not_to receive(:update_split_payment_state)

        payment.send(:sync_with_paypal)
        expect(payment.errors.first.message).to eq("Not all split payout parts are in the same state for payout #{payment.id}. This needs to be handled manually.")
      end
    end
  end
end
