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

  describe "#successful_sales" do
    let(:user) { create(:user) }
    let(:product) { create(:product, user: user) }
    let(:balance) { create(:balance, user: user) }
    let(:payment) { create(:payment, user: user, balances: [balance], payout_period_end_date: 3.days.ago) }

    it "includes all successful sales" do
      successful_sale = create(:purchase, seller: user, link: product, purchase_success_balance: balance)
      refunded_sale = create(:purchase, :refunded, seller: user, link: product, purchase_success_balance: balance)
      chargedback_sale = create(:purchase, seller: user, link: product, purchase_success_balance: balance, chargeback_date: 1.day.ago)

      sales = payment.successful_sales

      expect(sales).to include(successful_sale)
      expect(sales).to include(refunded_sale)
      expect(sales).to include(chargedback_sale)
      expect(sales.length).to eq(3)
    end

    it "returns sales sorted by created_at desc" do
      older_sale = create(:purchase, seller: user, link: product, purchase_success_balance: balance, created_at: 3.days.ago)
      newer_sale = create(:purchase, seller: user, link: product, purchase_success_balance: balance, created_at: 1.day.ago)
      middle_sale = create(:purchase, seller: user, link: product, purchase_success_balance: balance, created_at: 2.days.ago)

      sales = payment.successful_sales

      expect(sales).to eq([newer_sale, middle_sale, older_sale])
    end

    it "returns empty array when no successful sales" do
      sales = payment.successful_sales
      expect(sales).to be_empty
    end
  end

  describe "#refunded_sales" do
    let(:user) { create(:user) }
    let(:product) { create(:product, user: user) }
    let(:balance) { create(:balance, user: user) }
    let(:payment) { create(:payment, user: user, balances: [balance], payout_period_end_date: 3.days.ago) }

    it "includes only refunded sales from associated balances" do
      successful_sale = create(:purchase, seller: user, link: product, purchase_success_balance: balance)
      refunded_sale = create(:purchase, :refunded, seller: user, link: product, purchase_refund_balance: balance)

      sales = payment.refunded_sales

      expect(sales).to include(refunded_sale)
      expect(sales).not_to include(successful_sale)
      expect(sales.length).to eq(1)
    end

    it "returns sales sorted by created_at desc" do
      older_refunded = create(:purchase, :refunded, seller: user, link: product, purchase_refund_balance: balance, created_at: 3.days.ago)
      newer_refunded = create(:purchase, :refunded, seller: user, link: product, purchase_refund_balance: balance, created_at: 1.day.ago)

      sales = payment.refunded_sales

      expect(sales).to eq([newer_refunded, older_refunded])
    end

    it "returns empty array when no refunded sales" do
      sales = payment.refunded_sales
      expect(sales).to be_empty
    end
  end

  describe "#disputed_sales" do
    let(:user) { create(:user) }
    let(:product) { create(:product, user: user) }
    let(:balance) { create(:balance, user: user) }
    let(:payment) { create(:payment, user: user, balances: [balance], payout_period_end_date: 3.days.ago) }

    it "includes only chargedback sales from associated balances" do
      successful_sale = create(:purchase, seller: user, link: product, purchase_success_balance: balance)
      chargedback_sale = create(:purchase, seller: user, link: product, purchase_chargeback_balance: balance, chargeback_date: 1.day.ago)

      sales = payment.disputed_sales

      expect(sales).to include(chargedback_sale)
      expect(sales).not_to include(successful_sale)
      expect(sales.length).to eq(1)
    end

    it "returns sales sorted by created_at desc" do
      older_chargeback = create(:purchase, seller: user, link: product, purchase_chargeback_balance: balance, chargeback_date: 3.days.ago, created_at: 3.days.ago)
      newer_chargeback = create(:purchase, seller: user, link: product, purchase_chargeback_balance: balance, chargeback_date: 1.day.ago, created_at: 1.day.ago)

      sales = payment.disputed_sales

      expect(sales).to eq([newer_chargeback, older_chargeback])
    end

    it "returns empty array when no chargedback sales" do
      sales = payment.disputed_sales
      expect(sales).to be_empty
    end
  end

  describe "#as_json" do
    before do
      allow(ObfuscateIds).to receive(:encrypt).and_return("mocked_external_id")

      @payment = create(:payment,
                        amount_cents: 2500,
                        currency: "USD",
                        processor: PayoutProcessorType::STRIPE,
                        processor_fee_cents: 25)
    end

    it "has the right keys" do
      %i[id amount currency status created_at processed_at payment_processor bank_account_visual paypal_email].each do |key|
        expect(@payment.as_json.key?(key)).to be(true)
      end
    end

    it "returns external_id for the id field" do
      json = @payment.as_json
      expect(json[:id]).to eq("mocked_external_id")
    end

    it "returns the correct values for basic fields" do
      json = @payment.as_json

      expect(json[:amount]).to eq("25.00")
      expect(json[:currency]).to eq("USD")
      expect(json[:status]).to eq(@payment.state)
      expect(json[:created_at]).to eq(@payment.created_at)
      expect(json[:payment_processor]).to eq(PayoutProcessorType::STRIPE)
    end

    it "returns correct formatted amount" do
      @payment.update!(amount_cents: 12345)
      expect(@payment.as_json[:amount]).to eq("123.45")

      @payment.update!(amount_cents: 100)
      expect(@payment.as_json[:amount]).to eq("1.00")

      @payment.update!(amount_cents: 99)
      expect(@payment.as_json[:amount]).to eq("0.99")
    end

    context "when payment is not completed" do
      it "returns nil for processed_at in processing state" do
        @payment.update!(state: Payment::PROCESSING)
        expect(@payment.as_json[:processed_at]).to be_nil
      end

      it "returns nil for processed_at in failed state" do
        @payment.update!(state: Payment::FAILED)
        expect(@payment.as_json[:processed_at]).to be_nil
      end

      it "returns nil for processed_at in creating state" do
        @payment.update!(state: Payment::CREATING)
        expect(@payment.as_json[:processed_at]).to be_nil
      end
    end

    context "when payment is completed" do
      it "returns correct processed_at timestamp" do
        # Set required fields for state transition
        @payment.update!(
          txn_id: "test_txn_123",
          processor_fee_cents: 25,
          stripe_transfer_id: "tr_123",
          stripe_connect_account_id: "acct_123"
        )
        @payment.mark_completed!

        json = @payment.as_json
        expect(json[:processed_at]).to eq(@payment.updated_at)
        expect(json[:status]).to eq(Payment::COMPLETED)
      end
    end

    it "works with different payment processors" do
      paypal_payment = create(:payment, processor: PayoutProcessorType::PAYPAL)
      expect(paypal_payment.as_json[:payment_processor]).to eq(PayoutProcessorType::PAYPAL)

      stripe_payment = create(:payment, processor: PayoutProcessorType::STRIPE)
      expect(stripe_payment.as_json[:payment_processor]).to eq(PayoutProcessorType::STRIPE)
    end

    it "works with different currencies" do
      eur_payment = create(:payment, currency: "EUR", amount_cents: 5000)

      expect(eur_payment.as_json[:currency]).to eq("EUR")
      expect(eur_payment.as_json[:amount]).to eq("50.00")
    end

    it "handles zero amount correctly" do
      @payment.update!(amount_cents: 0)
      expect(@payment.as_json[:amount]).to eq("0.00")
    end

    context "bank_account_visual field" do
      it "includes bank_account_visual when payment has bank account" do
        bank_account = create(:ach_account, user: @payment.user)
        bank_account.update!(account_number_last_four: "1234")
        @payment.update!(bank_account: bank_account)

        json = @payment.as_json
        expect(json[:bank_account_visual]).to eq("******1234")
      end

      it "returns nil when payment has no bank account" do
        json = @payment.as_json
        expect(json[:bank_account_visual]).to be_nil
      end
    end

    context "paypal_email field" do
      it "includes paypal_email when payment has payment_address" do
        @payment.update!(payment_address: "seller@example.com")

        json = @payment.as_json
        expect(json[:paypal_email]).to eq("seller@example.com")
      end

      it "returns nil when payment has no payment_address" do
        json = @payment.as_json
        expect(json[:paypal_email]).to be_nil
      end
    end

    context "with include_sales option" do
      let(:user) { create(:user) }
      let(:product) { create(:product, user: user) }
      let(:balance) { create(:balance, user: user) }
      let(:payment) { create(:payment, user: user, balances: [balance]) }

      before do
        allow(ObfuscateIds).to receive(:encrypt).and_return("mocked_external_id")
      end

      context "when include_sales is true" do
        it "includes sales, refunded_sales, and disputed_sales ids" do
          successful_sale = create(:purchase, seller: user, link: product, purchase_success_balance: balance)
          refunded_sale = create(:purchase, :refunded, seller: user, link: product, purchase_refund_balance: balance)
          chargedback_sale = create(:purchase, seller: user, link: product, purchase_chargeback_balance: balance, chargeback_date: 1.day.ago)

          json = payment.as_json(include_sales: true)

          expect(json[:sales]).to be_an(Array)
          expect(json[:refunded_sales]).to be_an(Array)
          expect(json[:disputed_sales]).to be_an(Array)

          expect(json[:sales].length).to eq(1)
          expect(json[:refunded_sales].length).to eq(1)
          expect(json[:disputed_sales].length).to eq(1)

          expect(json[:sales].first).to be_a(String)
          expect(json[:sales].first).to eq(successful_sale.external_id)

          expect(json[:refunded_sales].first).to be_a(String)
          expect(json[:refunded_sales].first).to eq(refunded_sale.external_id)

          expect(json[:disputed_sales].first).to be_a(String)
          expect(json[:disputed_sales].first).to eq(chargedback_sale.external_id)
        end

        it "includes empty arrays when no sales of each type exist" do
          json = payment.as_json(include_sales: true)

          expect(json[:sales]).to eq([])
          expect(json[:refunded_sales]).to eq([])
          expect(json[:disputed_sales]).to eq([])
        end
      end

      context "when include_sales is false" do
        it "does not include sales keys in the response" do
          json = payment.as_json(include_sales: false)

          expect(json).not_to have_key(:sales)
          expect(json).not_to have_key(:refunded_sales)
          expect(json).not_to have_key(:disputed_sales)
        end
      end

      context "when include_sales option is not provided" do
        it "does not include sales keys in the response" do
          json = payment.as_json

          expect(json).not_to have_key(:sales)
          expect(json).not_to have_key(:refunded_sales)
          expect(json).not_to have_key(:disputed_sales)
        end
      end
    end
  end
end
