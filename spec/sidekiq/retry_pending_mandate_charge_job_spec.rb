# frozen_string_literal: true

require "spec_helper"

describe RetryPendingMandateChargeJob do
  it "does nothing for a missing order" do
    expect(Order::ConfirmService).not_to receive(:new)
    described_class.new.perform(0)
  end

  context "with a stubbed confirm service" do
    let(:order) { create(:order) }
    let(:purchase) { create(:purchase_in_progress, order:, stripe_transaction_id: nil) }
    let(:service) { instance_double(Order::ConfirmService, charge_pending_setup_groups!: {}, mandate_pending_purchases: [purchase]) }

    before do
      order.purchases << purchase
      allow(Order::ConfirmService).to receive(:new).with(order:, params: { buyer_currency_quote: nil }).and_return(service)
    end

    it "reschedules while a group is still held inside the wait window" do
      described_class.new.perform(order.id)

      expect(described_class.jobs.size).to eq(1)
      expect(purchase.reload.purchase_state).to eq("in_progress")
    end

    it "fails the held group with the pending-mandate error once the wait is over" do
      purchase.update!(created_at: (described_class::MAX_WAIT + 1.minute).ago)

      described_class.new.perform(order.id)

      expect(described_class.jobs).to be_empty
      purchase.reload
      expect(purchase.purchase_state).to eq("failed")
      expect(purchase.error_code).to eq(PurchaseErrorCode::INDIA_CARD_MANDATE_PENDING)
    end

    it "does not fail a held group that was charged in the meantime" do
      purchase.update!(created_at: (described_class::MAX_WAIT + 1.minute).ago)
      purchase.create_processor_payment_intent!(intent_id: "pi_paid")

      described_class.new.perform(order.id)

      expect(purchase.reload.purchase_state).to eq("in_progress")
      expect(purchase.error_code).to be_nil
    end

    it "finishes a declined group even while another group is still held" do
      declined = create(:purchase_in_progress, order:, stripe_transaction_id: nil)
      order.purchases << declined
      declined.errors.add(:base, "declined")
      allow(order).to receive(:purchases).and_return(order.purchases.to_a)
      allow(Order).to receive(:find_by).with(id: order.id).and_return(order)
      confirm = instance_double(Purchase::ConfirmService, perform: "declined")
      expect(Purchase::ConfirmService).to receive(:new).with(purchase: declined, params: { buyer_currency_quote: nil }).and_return(confirm)

      described_class.new.perform(order.id)

      expect(described_class.jobs.size).to eq(1)
    end

    it "does nothing more when the groups were charged" do
      allow(service).to receive(:mandate_pending_purchases).and_return([])

      described_class.new.perform(order.id)

      expect(described_class.jobs).to be_empty
    end
  end

  # Runs the real Order::ConfirmService charge path; only the Stripe boundary is stubbed.
  context "with India multi-seller groups paused at a SetupIntent" do
    let(:merchant_account) do
      MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
        create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: nil)
    end
    let(:india_card) do
      create(:indian_stripe_credit_card, stripe_customer_id: "cus_job_india", processor_payment_method_id: "pm_job_india", stripe_fingerprint: "job_india_fingerprint")
    end
    let(:order) { create(:order) }
    let(:mandate_statuses) { { "mandate_job_1" => "pending" } }
    let(:setup_intents) do
      { "seti_job_1" => instance_double(StripeSetupIntent, succeeded?: true, mandate: "mandate_job_1") }
    end
    # :charge receives the kwargs Charge::CreateService.new got and returns the charge it performs.
    let(:outcomes) { { charge: ->(kwargs) { raise "Charge::CreateService must not be called for #{kwargs[:purchases].map(&:id)}" } } }

    def create_group(setup_intent_id, price_cents: 5_00)
      seller = create(:user)
      charge = create(:charge, order:, seller:, merchant_account:, stripe_setup_intent_id: setup_intent_id)
      Array.new(2) do |index|
        purchase = create(:purchase_in_progress,
                          link: create(:product, user: seller, price_cents: price_cents + index),
                          seller:,
                          merchant_account:,
                          credit_card: india_card,
                          is_multi_buy: true,
                          processor_setup_intent_id: setup_intent_id,
                          stripe_transaction_id: nil)
        charge.purchases << purchase
        order.purchases << purchase
        purchase
      end
    end

    def processing_outcome(kwargs)
      charge = kwargs[:purchases].first.charge
      charge.charge_intent = StripeChargeIntent.new(
        payment_intent: Stripe::PaymentIntent.construct_from(id: "pi_job_#{charge.id}", status: StripeIntentStatus::PROCESSING)
      )
      charge
    end

    let!(:purchases) { create_group("seti_job_1") }

    before do
      allow(ChargeProcessor).to receive(:get_setup_intent) { |_merchant_account, id| setup_intents.fetch(id) }
      allow(ChargeProcessor).to receive(:get_mandate) { |_merchant_account, id| double(status: mandate_statuses.fetch(id)) }
      allow(Charge::CreateService).to receive(:new) do |**kwargs|
        instance_double(Charge::CreateService, processor_outcome_unknown: false).tap do |create_service|
          allow(create_service).to receive(:perform) { outcomes[:charge].call(kwargs) }
        end
      end
      allow_any_instance_of(Purchase).to receive(:increment_sellers_balance!)
      allow_any_instance_of(Purchase).to receive(:financial_transaction_validation)
    end

    it "keeps the groups in progress and reschedules while the mandate is pending inside the wait" do
      described_class.new.perform(order.id, "quote-token")

      expect(purchases.map { _1.reload.purchase_state }).to all(eq("in_progress"))
      expect(described_class.jobs.size).to eq(1)
      expect(described_class.jobs.first["args"]).to eq([order.id, "quote-token"])
    end

    it "fails the held groups with the pending-mandate error once the wait is over" do
      purchases.each { _1.update_column(:created_at, (described_class::MAX_WAIT + 1.minute).ago) }

      described_class.new.perform(order.id)

      purchases.each do |purchase|
        purchase.reload
        expect(purchase.purchase_state).to eq("failed")
        expect(purchase.error_code).to eq(PurchaseErrorCode::INDIA_CARD_MANDATE_PENDING)
      end
      expect(described_class.jobs).to be_empty
    end

    def age_purchases(by)
      purchases.each { _1.update_column(:created_at, by.ago) }
    end

    def expect_failed_with_pending_mandate_error
      purchases.each do |purchase|
        purchase.reload
        expect(purchase.purchase_state).to eq("failed")
        expect(purchase.error_code).to eq(PurchaseErrorCode::INDIA_CARD_MANDATE_PENDING)
        expect(purchase.stripe_status).to be_nil
      end
    end

    context "when a group is already held" do
      before do
        described_class.new.perform(order.id)
        described_class.jobs.clear
      end

      it "does not charge it after the wait even though the mandate has turned active" do
        age_purchases(described_class::MAX_WAIT + 1.minute)
        mandate_statuses["mandate_job_1"] = "active"
        outcomes[:charge] = ->(kwargs) { processing_outcome(kwargs) }
        expect(Charge::CreateService).not_to receive(:new)

        described_class.new.perform(order.id)

        expect_failed_with_pending_mandate_error
        expect(described_class.jobs).to be_empty
      end

      it "refuses a browser confirm that arrives after the wait" do
        age_purchases(described_class::MAX_WAIT + 1.minute)
        mandate_statuses["mandate_job_1"] = "active"
        expect(Charge::CreateService).not_to receive(:new)

        responses, = Order::ConfirmService.new(order: Order.find(order.id), params: {}).perform

        expect_failed_with_pending_mandate_error
        purchases.each { expect(responses[_1.id]).to include(success: false, error_message: described_class::PENDING_MESSAGE) }
      end

      it "reconciles a group whose charge was already submitted instead of failing it after the wait" do
        age_purchases(described_class::MAX_WAIT + 1.minute)
        purchases.first.charge.update!(client_confirmed: true)

        described_class.new.perform(order.id)

        expect(purchases.map { _1.reload.purchase_state }).to all(eq("in_progress"))
        expect(ReconcileClientConfirmedChargeJob.jobs.map { _1["args"].first }).to include(purchases.first.charge.id)
      end

      it "refuses a new checkout for the same product and email after the normal retry window" do
        age_purchases(ChargeProcessor::TIME_TO_COMPLETE_SCA + 5.minutes)
        held = purchases.first
        free_code = create(:offer_code, products: [held.link], amount_cents: nil, amount_percentage: 100)
        params = {
          purchase: {
            email: held.email, quantity: 1, perceived_price_cents: 0, discount_code: free_code.code,
            ip_address: "0.0.0.0", session_id: "a107d0b7ab5ab3c1eeb7d3aaf9792977", is_mobile: false, browser_guid: SecureRandom.uuid
          }
        }

        expect do
          _, error = Purchase::CreateService.new(product: held.link, params:).perform
          expect(error).to be_present
        end.not_to change { Purchase.where(link: held.link).successful.count }
      end

      context "when the wait ends while this run is talking to Stripe" do
        before do
          age_purchases(described_class::MAX_WAIT - 1.second)
          mandate_statuses["mandate_job_1"] = "active"
          outcomes[:charge] = ->(kwargs) { processing_outcome(kwargs) }
        end

        it "does not start a charge when the deadline passes during the mandate read" do
          allow(ChargeProcessor).to receive(:get_mandate) do
            travel 2.minutes
            double(status: "active")
          end
          expect(Charge::CreateService).not_to receive(:new)

          described_class.new.perform(order.id)

          expect_failed_with_pending_mandate_error
        end

        it "does not start a charge when the deadline passes while preparing the payment method" do
          allow_any_instance_of(Chargeable).to receive(:prepare_with_trusted_setup_intent!).and_wrap_original do |original, *args|
            original.call(*args).tap { travel 2.minutes }
          end
          expect(Charge::CreateService).not_to receive(:new)

          described_class.new.perform(order.id)

          expect_failed_with_pending_mandate_error
        end

        it "keeps a charge submitted before the deadline even when Stripe answers after it" do
          outcomes[:charge] = ->(kwargs) do
            travel 2.minutes
            processing_outcome(kwargs)
          end

          described_class.new.perform(order.id)

          purchases.each do |purchase|
            purchase.reload
            expect(purchase.purchase_state).to eq("in_progress")
            expect(purchase.processor_payment_intent).to be_present
          end
        end
      end

      it "keeps waiting when Stripe cannot be read inside the wait" do
        allow(ChargeProcessor).to receive(:get_setup_intent).and_raise(ChargeProcessorUnavailableError)

        described_class.new.perform(order.id)

        expect(purchases.map { _1.reload.purchase_state }).to all(eq("in_progress"))
        expect(described_class.jobs.size).to eq(1)
      end

      it "fails right away on an error that waiting cannot fix" do
        allow(ChargeProcessor).to receive(:get_setup_intent).and_raise(ChargeProcessorInvalidRequestError)

        described_class.new.perform(order.id)

        expect(purchases.map { _1.reload.purchase_state }).to all(eq("failed"))
        expect(described_class.jobs).to be_empty
      end

      it "keeps waiting instead of charging when the mandate cannot be read inside the wait" do
        allow(ChargeProcessor).to receive(:get_mandate).and_raise(ChargeProcessorUnavailableError)
        expect(Charge::CreateService).not_to receive(:new)

        described_class.new.perform(order.id)

        expect(purchases.map { _1.reload.purchase_state }).to all(eq("in_progress"))
        expect(described_class.jobs.size).to eq(1)
      end

      it "stops waiting when the mandate read fails for a reason waiting cannot fix" do
        allow(ChargeProcessor).to receive(:get_mandate).and_raise(ChargeProcessorInvalidRequestError)
        # Stripe still refuses a charge on a pending mandate, so the group fails closed right away.
        outcomes[:charge] = ->(kwargs) do
          kwargs[:purchases].each do |purchase|
            purchase.error_code = PurchaseErrorCode::INDIA_CARD_MANDATE_PENDING
            purchase.errors.add(:base, described_class::PENDING_MESSAGE)
          end
          kwargs[:purchases].first.charge
        end

        described_class.new.perform(order.id)

        expect(purchases.map { _1.reload.purchase_state }).to all(eq("failed"))
        expect(described_class.jobs).to be_empty
      end

      it "keeps the group held when a later confirm reports a browser error" do
        responses, = Order::ConfirmService.new(order: Order.find(order.id), params: { stripe_error: { code: "card_declined", message: "declined" } }).perform

        purchases.each do |purchase|
          expect(purchase.reload.purchase_state).to eq("in_progress")
          expect(responses[purchase.id]).to include(success: true, processing: true)
        end
      end

      it "fails it from the abandoned-purchase check when the retry chain was lost" do
        age_purchases(ChargeProcessor::TIME_TO_COMPLETE_SCA + 1.minute)
        expect(Stripe::SetupIntent).not_to receive(:retrieve)

        FailAbandonedPurchaseWorker.new.perform(purchases.first.id)

        expect(purchases.first.reload.purchase_state).to eq("in_progress")
        expect(FailAbandonedPurchaseWorker.jobs.size).to eq(1)

        age_purchases(described_class::MAX_WAIT + ChargeProcessor::TIME_TO_COMPLETE_SCA + 1.minute)
        purchases.each { FailAbandonedPurchaseWorker.new.perform(_1.id) }

        expect_failed_with_pending_mandate_error
      end
    end

    # Held before held groups were marked: stripe_status is still nil.
    context "with a hold saved before the processing marker existed" do
      it "does not charge it after the wait even once the mandate is active" do
        age_purchases(described_class::MAX_WAIT + 1.minute)
        mandate_statuses["mandate_job_1"] = "active"
        expect(Charge::CreateService).not_to receive(:new)

        described_class.new.perform(order.id)

        expect_failed_with_pending_mandate_error
        expect(described_class.jobs).to be_empty
      end

      it "marks it for repeat-purchase protection when it is rechecked inside the wait" do
        described_class.new.perform(order.id)

        purchases.each do |purchase|
          purchase.reload
          expect(purchase.purchase_state).to eq("in_progress")
          expect(purchase.stripe_status).to eq(StripeIntentStatus::PROCESSING)
        end
        expect(described_class.jobs.size).to eq(1)
      end

      it "reconciles it after the wait when its charge was already submitted" do
        age_purchases(described_class::MAX_WAIT + 1.minute)
        purchases.first.charge.update!(client_confirmed: true)

        described_class.new.perform(order.id)

        expect(purchases.map { _1.reload.purchase_state }).to all(eq("in_progress"))
        expect(ReconcileClientConfirmedChargeJob.jobs.map { _1["args"].first }).to include(purchases.first.charge.id)
      end
    end

    it "schedules the retry before finishing the other line items" do
      unrelated = create(:purchase_in_progress, order:, stripe_transaction_id: nil)
      order.purchases << unrelated
      allow(Purchase::ConfirmService).to receive(:new).and_call_original
      allow(Purchase::ConfirmService).to receive(:new).with(purchase: unrelated, params: anything).and_raise(ChargeProcessorUnavailableError)

      expect { Order::ConfirmService.new(order: Order.find(order.id), params: {}).perform }.to raise_error(ChargeProcessorUnavailableError)

      expect(described_class.jobs.size).to eq(1)
    end

    it "never fails a group that a concurrent confirm charged once the mandate turned active" do
      purchases.each { _1.update_column(:created_at, (described_class::MAX_WAIT + 1.minute).ago) }
      outcomes[:charge] = ->(kwargs) { processing_outcome(kwargs) }
      # A browser confirm POST for another account's group re-enters the same charge path. It
      # runs right after this job's charge pass returns, when the mandate has just turned active.
      allow_any_instance_of(Order::ConfirmService).to receive(:charge_pending_setup_groups!).and_wrap_original do |original, *args|
        result = original.call(*args)
        mandate_statuses["mandate_job_1"] = "active"
        Order::ConfirmService.new(order: Order.find(order.id), params: {}).perform
        result
      end

      described_class.new.perform(order.id)

      purchases.each(&:reload)
      charged_but_failed = purchases.select { _1.failed? && _1.processor_payment_intent.present? }
      expect(charged_but_failed).to be_empty
    end

    context "when another seller group is charged in the same run" do
      let!(:other_purchases) { create_group("seti_job_2", price_cents: 7_00) }

      before do
        setup_intents["seti_job_2"] = instance_double(StripeSetupIntent, succeeded?: true, mandate: "mandate_job_2")
        mandate_statuses["mandate_job_2"] = "active"
      end

      it "fails a declined group right away while still holding the pending group" do
        outcomes[:charge] = ->(kwargs) do
          kwargs[:purchases].each do |purchase|
            purchase.error_code = PurchaseErrorCode::STRIPE_INSUFFICIENT_FUNDS
            purchase.errors.add(:base, "Your card has insufficient funds.")
          end
          kwargs[:purchases].first.charge
        end

        described_class.new.perform(order.id)

        expect(other_purchases.map { _1.reload.purchase_state }).to all(eq("failed"))
        expect(purchases.map { _1.reload.purchase_state }).to all(eq("in_progress"))
        expect(described_class.jobs.size).to eq(1)
      end
    end

    it "sends the charge receipt when the resumed charge succeeds" do
      mandate_statuses["mandate_job_1"] = "active"
      allow_any_instance_of(StripeChargeProcessor).to receive(:get_charge).with("ch_job_succeeded", merchant_account: nil).and_return(instance_double(StripeCharge))
      outcomes[:charge] = ->(kwargs) do
        charge = kwargs[:purchases].first.charge
        charge.charge_intent = StripeChargeIntent.new(
          payment_intent: Stripe::PaymentIntent.construct_from(id: "pi_job_succeeded", status: StripeIntentStatus::SUCCESS, latest_charge: "ch_job_succeeded")
        )
        charge
      end
      allow(Purchase::FinalizeConfirmedChargeService).to receive(:new) do |purchase:, charge_intent:|
        instance_double(Purchase::FinalizeConfirmedChargeService).tap do |finalizer|
          allow(finalizer).to receive(:perform) { purchase.update_column(:purchase_state, "successful") && nil }
        end
      end

      described_class.new.perform(order.id)

      expect(purchases.map { _1.reload.purchase_state }).to all(eq("successful"))
      expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(purchases.first.charge.id)
    end
  end
end
