# frozen_string_literal: true

require "spec_helper"

describe Charge::Refundable do
  describe "#handle_event_refund_failed!" do
    let(:purchase) { create(:purchase, stripe_transaction_id: "ch_failed_#{SecureRandom.hex(6)}") }

    def build_failed_event(refund_id:, refund_status: "failed")
      event = ChargeEvent.new
      event.charge_processor_id = StripeChargeProcessor.charge_processor_id
      event.charge_event_id = "evt_#{SecureRandom.hex(6)}"
      event.charge_id = purchase.stripe_transaction_id
      event.refund_id = refund_id
      event.type = ChargeEvent::TYPE_REFUND_FAILED
      event.extras = { refund_status:, refunded_amount_cents: 100, refund_reason: nil }
      event
    end

    it "alerts on a failure for a refund with no Gumroad record" do
      # An unmatched FAILURE on the platform endpoint means money moved back to us
      # with no book entry to reconcile against — it must be alerted, not dropped.
      expect(ErrorNotifier).to receive(:notify).with(/no Gumroad record/)

      purchase.handle_event_refund_failed!(build_failed_event(refund_id: "re_unmatched_#{SecureRandom.hex(6)}"))
    end

    it "routes a matched failure through the failure handler with Stripe's actual status" do
      refund = create(:refund, purchase:, processor_refund_id: "re_matched_#{SecureRandom.hex(6)}", status: "pending")

      service = instance_double(Purchase::HandleFailedRefundService, perform: true)
      expect(Purchase::HandleFailedRefundService).to receive(:new)
        .with(refund:, failure_status: "canceled").and_return(service)

      purchase.handle_event_refund_failed!(build_failed_event(refund_id: refund.processor_refund_id, refund_status: "canceled"))
    end

    describe "combined charges with multiple purchases" do
      # One Stripe refund on a combined charge is recorded as one Refund row per
      # purchase, all sharing the processor refund id. When that single Stripe
      # refund bounces, every purchase's books must be unwound — a fan-out that
      # only exists on this path, so it gets a real (unstubbed) reversal test.
      let(:seller_one) { create(:user) }
      let(:seller_two) { create(:user) }
      let(:purchase_one) do
        create(:purchase_with_balance,
               link: create(:product, user: seller_one, price_cents: 10_00),
               seller: seller_one,
               price_cents: 10_00,
               total_transaction_cents: 10_00,
               is_part_of_combined_charge: true)
      end
      let(:purchase_two) do
        create(:purchase_with_balance,
               link: create(:product, user: seller_two, price_cents: 5_00),
               seller: seller_two,
               price_cents: 5_00,
               total_transaction_cents: 5_00,
               is_part_of_combined_charge: true)
      end
      let!(:charge) do
        create(:charge,
               processor_transaction_id: "ch_combined_failed_#{SecureRandom.hex(6)}",
               amount_cents: 15_00,
               purchases: [purchase_one, purchase_two])
      end

      def record_refund_debit!(purchase, refund)
        amount = BalanceTransaction::Amount.new(
          currency: Currency::USD,
          gross_cents: -refund.amount_cents,
          net_cents: -refund.amount_cents
        )
        BalanceTransaction.create!(
          user: purchase.seller,
          merchant_account: purchase.merchant_account,
          refund:,
          issued_amount: amount,
          holding_amount: amount
        )
        purchase.update!(stripe_refunded: true, stripe_partially_refunded: false)
      end

      it "reverses every purchase's refund when the shared Stripe refund fails" do
        processor_refund_id = "re_combined_#{SecureRandom.hex(6)}"
        refund_one = create(:refund, purchase: purchase_one, amount_cents: 10_00,
                                     total_transaction_cents: 10_00, gumroad_tax_cents: 0,
                                     processor_refund_id:, status: "pending")
        refund_two = create(:refund, purchase: purchase_two, amount_cents: 5_00,
                                     total_transaction_cents: 5_00, gumroad_tax_cents: 0,
                                     processor_refund_id:, status: "pending")
        record_refund_debit!(purchase_one, refund_one)
        record_refund_debit!(purchase_two, refund_two)

        expect do
          charge.handle_event_refund_failed!(build_failed_event(refund_id: processor_refund_id))
        end.to change(FailedRefundException, :count).by(2)

        [[refund_one, purchase_one, 10_00], [refund_two, purchase_two, 5_00]].each do |refund, purchase, price_cents|
          refund.reload
          expect(refund.status).to eq("failed")
          expect(refund.balance_reversed_on_failure).to eq(true)
          transactions = BalanceTransaction.where(refund_id: refund.id)
          expect(transactions.count).to eq(2)
          expect(transactions.sum(:issued_amount_net_cents)).to eq(0)

          purchase.reload
          expect(purchase.stripe_refunded?).to eq(false)
          expect(purchase.stripe_partially_refunded?).to eq(false)
          expect(purchase.purchase_refund_balance_id).to be_nil
          expect(purchase.amount_refundable_cents).to eq(price_cents)
        end
      end
    end
  end

  describe "#handle_event_refund_updated!" do
    describe "failed refunds are frozen" do
      let(:purchase) { create(:purchase, stripe_transaction_id: "ch_frozen_#{SecureRandom.hex(6)}") }

      it "does not let a late refund.updated overwrite a failed status" do
        # A stale "pending" update (Stripe retry delivered after the failure landed)
        # must not resurrect the refund: the failure handling already reversed the
        # balance debits, so flipping status off "failed" would make the bounced
        # refund count as delivered money again and block re-refunding.
        refund = create(:refund, purchase:, processor_refund_id: "re_frozen_#{SecureRandom.hex(6)}", status: "failed")

        event = ChargeEvent.new
        event.charge_processor_id = StripeChargeProcessor.charge_processor_id
        event.charge_id = purchase.stripe_transaction_id
        event.refund_id = refund.processor_refund_id
        event.type = ChargeEvent::TYPE_CHARGE_REFUND_UPDATED
        event.extras = { refund_status: "pending", refunded_amount_cents: 100, refund_reason: nil }

        purchase.handle_event_refund_updated!(event)

        expect(refund.reload.status).to eq("failed")
      end

      it "does not let a late refund.updated overwrite a canceled status" do
        # "canceled" is just as terminal as "failed": the unwind already ran, so a
        # stale update must not resurrect the refund as pending/succeeded money.
        refund = create(:refund, purchase:, processor_refund_id: "re_frozen_#{SecureRandom.hex(6)}", status: "canceled")

        event = ChargeEvent.new
        event.charge_processor_id = StripeChargeProcessor.charge_processor_id
        event.charge_id = purchase.stripe_transaction_id
        event.refund_id = refund.processor_refund_id
        event.type = ChargeEvent::TYPE_CHARGE_REFUND_UPDATED
        event.extras = { refund_status: "pending", refunded_amount_cents: 100, refund_reason: nil }

        purchase.handle_event_refund_updated!(event)

        expect(refund.reload.status).to eq("canceled")
      end

      it "freezes a refund whose balance was reversed even if its status is not terminal" do
        # The balance_reversed_on_failure marker alone must block status writes: if a
        # stale update rewrote the row, the save would also write back the stale
        # (unset) marker, letting a redelivered failure reverse the same money twice.
        refund = create(:refund, purchase:, processor_refund_id: "re_frozen_#{SecureRandom.hex(6)}", status: "pending")
        refund.balance_reversed_on_failure = true
        refund.save!

        event = ChargeEvent.new
        event.charge_processor_id = StripeChargeProcessor.charge_processor_id
        event.charge_id = purchase.stripe_transaction_id
        event.refund_id = refund.processor_refund_id
        event.type = ChargeEvent::TYPE_CHARGE_REFUND_UPDATED
        event.extras = { refund_status: "succeeded", refunded_amount_cents: 100, refund_reason: nil }

        purchase.handle_event_refund_updated!(event)

        refund.reload
        expect(refund.status).to eq("pending")
        expect(refund.balance_reversed_on_failure).to eq(true)
      end

      it "re-checks the guard under the row lock so a failure landing mid-flight is not overwritten" do
        # The failure handler can commit between this handler loading its refund rows
        # and saving them. The pre-lock snapshot still says "pending", so without a
        # locked re-check the save would resurrect the failed status (and write back
        # stale json_data, erasing the balance-reversal marker). Simulate that race by
        # handing the handler a snapshot taken before the failure landed.
        refund = create(:refund, purchase:, processor_refund_id: "re_race_#{SecureRandom.hex(6)}", status: "pending")
        stale_snapshot = Refund.find(refund.id)
        allow(Refund).to receive(:where).with(processor_refund_id: refund.processor_refund_id).and_return([stale_snapshot])

        # The failure lands after the snapshot was taken.
        refund.update_column(:status, "failed")

        event = ChargeEvent.new
        event.charge_processor_id = StripeChargeProcessor.charge_processor_id
        event.charge_id = purchase.stripe_transaction_id
        event.refund_id = refund.processor_refund_id
        event.type = ChargeEvent::TYPE_CHARGE_REFUND_UPDATED
        event.extras = { refund_status: "succeeded", refunded_amount_cents: 100, refund_reason: nil }

        purchase.handle_event_refund_updated!(event)

        expect(refund.reload.status).to eq("failed")
      end
    end

    let(:purchase) do
      create(:purchase,
             price_cents: 10_00,
             total_transaction_cents: 10_00,
             stripe_transaction_id: "ch_refundable_#{SecureRandom.hex(6)}")
    end

    def build_event(refunded_amount_cents:)
      event = ChargeEvent.new
      event.charge_processor_id = StripeChargeProcessor.charge_processor_id
      event.charge_id = purchase.stripe_transaction_id
      event.refund_id = "re_refundable_#{SecureRandom.hex(6)}"
      event.type = ChargeEvent::TYPE_CHARGE_REFUND_UPDATED
      event.extras = { refund_status: "succeeded", refunded_amount_cents:, refund_reason: nil }
      event
    end

    def stub_stripe_refund(presentment_cents:, currency: Currency::CAD)
      stripe_refund = double("stripe_refund", status: "succeeded", id: "re_refundable_#{SecureRandom.hex(6)}")
      charge_refund = ChargeRefund.new
      charge_refund.charge_processor_id = StripeChargeProcessor.charge_processor_id
      charge_refund.id = stripe_refund.id
      charge_refund.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(currency, -presentment_cents)
      charge_refund.instance_variable_set(:@refund, stripe_refund)
      allow_any_instance_of(StripeChargeProcessor).to receive(:get_refund).and_return(charge_refund)
      charge_refund
    end

    describe "buyer-presentment purchases" do
      before do
        create(:purchase_presentment,
               purchase:,
               presentment_currency: Currency::CAD,
               presentment_price_cents: 13_50,
               presentment_gumroad_tax_cents: 0,
               presentment_total_cents: 13_50)
        purchase.association(:purchase_presentment).reset
      end

      it "records the refund when Stripe reports the full presentment amount" do
        stub_stripe_refund(presentment_cents: 13_50)

        purchase.handle_event_refund_updated!(build_event(refunded_amount_cents: 13_50))

        purchase.reload
        expect(purchase.stripe_refunded?).to be(true)
        refund = purchase.refunds.last
        expect(refund.total_transaction_cents).to eq(10_00)
        expect(refund.presentment_currency).to eq(Currency::CAD)
        expect(refund.presentment_amount_cents).to eq(13_50)
      end

      it "records a partial processor-initiated refund with a derived canonical amount" do
        stub_stripe_refund(presentment_cents: 4_50)

        purchase.handle_event_refund_updated!(build_event(refunded_amount_cents: 4_50))

        purchase.reload
        expect(purchase.stripe_refunded?).to be(false)
        expect(purchase.stripe_partially_refunded?).to be(true)
        refund = purchase.refunds.last
        expect(refund.presentment_currency).to eq(Currency::CAD)
        expect(refund.presentment_amount_cents).to eq(4_50)
        # 4_50 / 13_50 of the canonical 10_00, allocated by largest remainder
        expect(refund.total_transaction_cents).to eq(3_33)
      end

      it "records repeated partial refunds until the presentment total is exhausted" do
        stub_stripe_refund(presentment_cents: 4_50)
        purchase.handle_event_refund_updated!(build_event(refunded_amount_cents: 4_50))

        stub_stripe_refund(presentment_cents: 9_00)
        purchase.handle_event_refund_updated!(build_event(refunded_amount_cents: 9_00))

        purchase.reload
        expect(purchase.stripe_refunded?).to be(true)
        expect(purchase.refunds.sum { _1.presentment_amount_cents.to_i }).to eq(13_50)
        expect(purchase.refunds.sum(:total_transaction_cents)).to eq(10_00)
      end

      it "ignores amounts above the presentment total" do
        purchase.handle_event_refund_updated!(build_event(refunded_amount_cents: 14_00))

        expect(purchase.reload.refunds).to be_empty
        expect(purchase.stripe_refunded?).to be(false)
      end

      it "does not treat the canonical USD amount as a full refund" do
        stub_stripe_refund(presentment_cents: 10_00)

        purchase.handle_event_refund_updated!(build_event(refunded_amount_cents: 10_00))

        purchase.reload
        expect(purchase.stripe_refunded?).to be(false)
        expect(purchase.stripe_partially_refunded?).to be(true)
        expect(purchase.refunds.last.presentment_amount_cents).to eq(10_00)
      end
    end

    describe "canonical purchases" do
      it "records the refund when Stripe reports the full canonical amount" do
        stub_stripe_refund(presentment_cents: 10_00, currency: Currency::USD)

        purchase.handle_event_refund_updated!(build_event(refunded_amount_cents: 10_00))

        purchase.reload
        expect(purchase.stripe_refunded?).to be(true)
        expect(purchase.refunds.last.total_transaction_cents).to eq(10_00)
      end

      it "records a partial processor-initiated refund" do
        stub_stripe_refund(presentment_cents: 3_00, currency: Currency::USD)

        purchase.handle_event_refund_updated!(build_event(refunded_amount_cents: 3_00))

        purchase.reload
        expect(purchase.stripe_refunded?).to be(false)
        expect(purchase.stripe_partially_refunded?).to be(true)
        expect(purchase.refunds.last.total_transaction_cents).to eq(3_00)
      end

      it "records repeated partial refunds until the charge is fully refunded" do
        stub_stripe_refund(presentment_cents: 3_00, currency: Currency::USD)
        purchase.handle_event_refund_updated!(build_event(refunded_amount_cents: 3_00))

        stub_stripe_refund(presentment_cents: 7_00, currency: Currency::USD)
        purchase.handle_event_refund_updated!(build_event(refunded_amount_cents: 7_00))

        purchase.reload
        expect(purchase.stripe_refunded?).to be(true)
        expect(purchase.refunds.sum(:total_transaction_cents)).to eq(10_00)
      end

      it "ignores zero and over-refundable amounts" do
        purchase.handle_event_refund_updated!(build_event(refunded_amount_cents: 0))
        purchase.handle_event_refund_updated!(build_event(refunded_amount_cents: 11_00))

        expect(purchase.reload.refunds).to be_empty
        expect(purchase.stripe_refunded?).to be(false)
        expect(purchase.stripe_partially_refunded?).to be(false)
      end
    end

    describe "deduplication against already-recorded refunds" do
      # A seller-initiated refund creates the Stripe refund and the local Refund row
      # inside one long transaction, so the webhook's initial Refund lookup can run
      # before that transaction commits and miss the row. These specs simulate that
      # race: the initial lookup comes back empty, but by the time the handler holds
      # the purchase row lock the seller's row is visible.
      def build_event_for(refund_id, refunded_amount_cents:)
        event = ChargeEvent.new
        event.charge_processor_id = StripeChargeProcessor.charge_processor_id
        event.charge_id = purchase.stripe_transaction_id
        event.refund_id = refund_id
        event.type = ChargeEvent::TYPE_CHARGE_REFUND_UPDATED
        event.extras = { refund_status: "succeeded", refunded_amount_cents:, refund_reason: nil }
        event
      end

      def simulate_initial_lookup_missing(refund_id)
        # First `Refund.where(processor_refund_id:)` call (the handler's entry lookup)
        # returns empty, as if the seller's transaction had not committed yet; later
        # calls (the re-check under the purchase row lock) hit the real database.
        calls = 0
        allow(Refund).to receive(:where).and_wrap_original do |m, *args, **kwargs|
          if args == [{ processor_refund_id: refund_id }] || kwargs == { processor_refund_id: refund_id }
            calls += 1
            next Refund.none if calls == 1
          end
          m.call(*args, **kwargs)
        end
      end

      it "does not re-record a partial refund the seller already recorded" do
        refund_id = "re_dup_#{SecureRandom.hex(6)}"
        # Partial refund: stripe_refunded stays false, so before the locked re-check
        # this handler would have recorded the same Stripe refund a second time.
        seller_refund = create(:refund, purchase:, processor_refund_id: refund_id,
                                        amount_cents: 3_00, total_transaction_cents: 3_00)
        purchase.update!(stripe_partially_refunded: true)
        simulate_initial_lookup_missing(refund_id)
        stub_stripe_refund(presentment_cents: 3_00, currency: Currency::USD)

        expect(ContactingCreatorMailer).not_to receive(:purchase_refunded)

        expect do
          purchase.handle_event_refund_updated!(build_event_for(refund_id, refunded_amount_cents: 3_00))
        end.not_to change { purchase.reload.refunds.count }

        expect(purchase.refunds).to eq([seller_refund])
        expect(BalanceTransaction.where(refund_id: seller_refund.id)).to be_empty
      end

      it "does not re-record the refund when Stripe redelivers the webhook after the row is visible" do
        # Second delivery of the same refund id once the Refund row IS visible: the
        # handler's entry lookup finds it and takes the status-update branch instead
        # of recording money again.
        stub_stripe_refund(presentment_cents: 10_00, currency: Currency::USD)
        event = build_event(refunded_amount_cents: 10_00)
        purchase.handle_event_refund_updated!(event)
        expect(purchase.reload.refunds.count).to eq(1)

        expect(ContactingCreatorMailer).not_to receive(:purchase_refunded)
        expect do
          purchase.handle_event_refund_updated!(event)
        end.not_to change { purchase.reload.refunds.count }
      end
    end

    describe "refunds created outside the app on a Gumroad-managed destination charge" do
      let(:seller) { create(:user) }
      let(:merchant_account) { create(:merchant_account, user: seller) }
      let(:product) { create(:product, user: seller, price_cents: 10_00) }
      let(:purchase) do
        create(:purchase_with_balance, link: product, seller:, price_cents: 10_00, total_transaction_cents: 10_00,
                                       merchant_account:, stripe_transaction_id: "ch_external_#{SecureRandom.hex(6)}")
      end
      let(:refund_id) { "re_external_#{SecureRandom.hex(6)}" }
      let(:transfer) { Stripe::StripeObject.construct_from(id: "tr_external", amount: 8_50, amount_reversed: 0) }
      let(:stripe_charge) do
        Stripe::StripeObject.construct_from(id: purchase.stripe_transaction_id, amount: 10_00, amount_refunded: 10_00,
                                            destination: merchant_account.charge_processor_merchant_id, transfer: transfer.id)
      end

      def build_external_event
        event = ChargeEvent.new
        event.charge_processor_id = StripeChargeProcessor.charge_processor_id
        event.charge_id = purchase.stripe_transaction_id
        event.refund_id = refund_id
        event.type = ChargeEvent::TYPE_CHARGE_REFUND_UPDATED
        event.extras = { refund_status: "succeeded", refunded_amount_cents: 10_00, refund_reason: nil }
        event
      end

      def charge_refund_with(merchant_cents: nil, transfer_reversal: nil)
        refund = Stripe::StripeObject.construct_from(id: refund_id, amount: 10_00, charge: stripe_charge.id, status: "succeeded",
                                                     currency: "usd", transfer_reversal:)
        charge_refund = StripeChargeRefund.allocate
        charge_refund.instance_variable_set(:@charge, stripe_charge)
        charge_refund.charge_processor_id = StripeChargeProcessor.charge_processor_id
        charge_refund.id = refund_id
        charge_refund.instance_variable_set(:@refund, refund)
        usd = ->(cents) { FlowOfFunds::Amount.new(currency: Currency::USD, cents:) }
        charge_refund.flow_of_funds = FlowOfFunds.new(
          issued_amount: usd.(-10_00), settled_amount: usd.(-10_00),
          gumroad_amount: usd.(merchant_cents ? -(10_00 - merchant_cents) : -10_00),
          merchant_account_gross_amount: merchant_cents && usd.(-merchant_cents),
          merchant_account_net_amount: merchant_cents && usd.(-merchant_cents)
        )
        charge_refund
      end

      before do
        purchase
        allow(Stripe::Transfer).to receive(:retrieve).with(transfer.id).and_return(transfer)
        allow_any_instance_of(StripeChargeProcessor).to receive(:get_refund) do |_processor, _id, destination_payment_refund_id: nil, **|
          destination_payment_refund_id ? charge_refund_with(merchant_cents: 8_50) : charge_refund_with
        end
        allow(ErrorNotifier).to receive(:notify)
      end

      def seller_refund_debits
        BalanceTransaction.where(user_id: seller.id).where.not(refund_id: nil)
      end

      it "reverses the transfer for the refunded share and debits the seller exactly that amount once" do
        allow(Stripe::Transfer).to receive(:list_reversals).and_return([])
        expect(Stripe::Transfer).to receive(:create_reversal).with(
          transfer.id,
          { amount: 8_50, refund_application_fee: true, metadata: { "external_refund_id" => refund_id } },
          { idempotency_key: "external_refund_reversal_#{refund_id}" }
        ).once.and_return(Stripe::StripeObject.construct_from(id: "trr_1", destination_payment_refund: "pyr_1"))

        purchase.handle_event_refund_updated!(build_external_event)

        refund = purchase.reload.refunds.sole
        expect(purchase.stripe_refunded?).to be(true)
        expect(refund.gumroad_funded).to be_nil
        expect(seller_refund_debits.sole.holding_amount_gross_cents).to eq(-8_50)
        expect(ErrorNotifier).to have_received(:notify).with(Charge::Refundable::EXTERNAL_REFUND_ALERT,
                                                             hash_including(stripe_refund_id: refund_id, transfer_outcome: :reversed_by_gumroad, recorded: true))
        expect(ErrorNotifier).not_to have_received(:notify).with(/Gumroad-funded/, anything)
      end

      it "uses the flow of funds as read when the refund itself reversed the transfer" do
        allow_any_instance_of(StripeChargeProcessor).to receive(:get_refund).and_return(charge_refund_with(merchant_cents: 8_50, transfer_reversal: "trr_1"))
        expect(Stripe::Transfer).not_to receive(:retrieve)
        expect(Stripe::Transfer).not_to receive(:create_reversal)

        purchase.handle_event_refund_updated!(build_external_event)

        expect(seller_refund_debits.sole.holding_amount_gross_cents).to eq(-8_50)
        expect(ErrorNotifier).to have_received(:notify).with(Charge::Refundable::EXTERNAL_REFUND_ALERT,
                                                             hash_including(transfer_outcome: :reversed_by_stripe))
      end

      it "reads the flow of funds from Stripe's reversal when the refund already reversed the transfer" do
        allow(Stripe::Transfer).to receive(:list_reversals).and_return(
          [Stripe::StripeObject.construct_from(id: "trr_stripe", source_refund: refund_id, destination_payment_refund: "pyr_2")]
        )
        expect(Stripe::Transfer).not_to receive(:create_reversal)

        purchase.handle_event_refund_updated!(build_external_event)

        expect(seller_refund_debits.sole.holding_amount_gross_cents).to eq(-8_50)
        expect(ErrorNotifier).to have_received(:notify).with(Charge::Refundable::EXTERNAL_REFUND_ALERT,
                                                             hash_including(transfer_outcome: :reversed_by_stripe))
      end

      it "books the refund as Gumroad-funded with no seller debit and alerts when no reversible transfer exists" do
        transfer.amount_reversed = 8_50
        allow(Stripe::Transfer).to receive(:list_reversals).and_return([])
        expect(Stripe::Transfer).not_to receive(:create_reversal)
        balance_before = seller.reload.unpaid_balance_cents

        purchase.handle_event_refund_updated!(build_external_event)

        refund = purchase.reload.refunds.sole
        expect(purchase.stripe_refunded?).to be(true)
        expect(refund.gumroad_funded).to be(true)
        expect(seller_refund_debits).to be_empty
        expect(seller.reload.unpaid_balance_cents).to eq(balance_before)
        expect(ErrorNotifier).to have_received(:notify).with(
          "Refund created outside the app booked as Gumroad-funded: seller transfer not reversible",
          hash_including(stripe_refund_id: refund_id, stripe_charge_id: purchase.stripe_transaction_id, refunded_amount_cents: 10_00)
        )
      end

      it "books the refund as Gumroad-funded when Stripe refuses the reversal" do
        allow(Stripe::Transfer).to receive(:list_reversals).and_return([])
        allow(Stripe::Transfer).to receive(:create_reversal).and_raise(Stripe::InvalidRequestError.new("Transfer already paid out", nil))

        purchase.handle_event_refund_updated!(build_external_event)

        expect(purchase.reload.refunds.sole.gumroad_funded).to be(true)
        expect(seller_refund_debits).to be_empty
        expect(ErrorNotifier).to have_received(:notify).with(/Gumroad-funded/, hash_including(transfer_outcome: :not_reversible))
      end

      it "does nothing twice when the webhook is redelivered" do
        allow(Stripe::Transfer).to receive(:list_reversals).and_return([])
        expect(Stripe::Transfer).to receive(:create_reversal).once
          .and_return(Stripe::StripeObject.construct_from(id: "trr_1", destination_payment_refund: "pyr_1"))
        # Both deliveries miss the entry lookup, as if the first had not committed yet.
        allow(Refund).to receive(:where).and_wrap_original do |m, *args, **kwargs|
          next Refund.none if kwargs == { processor_refund_id: refund_id } || args == [{ processor_refund_id: refund_id }]
          m.call(*args, **kwargs)
        end

        2.times { purchase.handle_event_refund_updated!(build_external_event) }

        expect(Refund.unscoped.where(purchase_id: purchase.id).count).to eq(1)
        expect(seller_refund_debits.count).to eq(1)
        expect(ErrorNotifier).to have_received(:notify).with(Charge::Refundable::EXTERNAL_REFUND_ALERT, anything).once
      end

      context "when the charge already has an application-fee refund" do
        let(:stripe_charge) do
          Stripe::StripeObject.construct_from(id: purchase.stripe_transaction_id, amount: 10_00, amount_refunded: 10_00,
                                              destination: merchant_account.charge_processor_merchant_id, transfer: transfer.id,
                                              application_fee: { id: "fee_1", refunds: { data: [{ id: "fr_earlier", amount: 50 }] } })
        end

        it "does not reverse or book the refund, and alerts, because the new fee refund cannot be paired" do
          allow(Stripe::Transfer).to receive(:list_reversals).and_return([])
          expect(Stripe::Transfer).not_to receive(:create_reversal)

          purchase.handle_event_refund_updated!(build_external_event)

          expect(purchase.reload.refunds).to be_empty
          expect(seller_refund_debits).to be_empty
          expect(ErrorNotifier).to have_received(:notify).with(Charge::Refundable::EXTERNAL_REFUND_ALERT,
                                                               hash_including(transfer_outcome: :fee_refund_unpaired, recorded: false))
        end

        it "does not book Stripe's own reversal when more than one fee refund exists" do
          stripe_charge.application_fee.refunds.data << Stripe::StripeObject.construct_from(id: "fr_this", amount: 1_50)
          allow_any_instance_of(StripeChargeProcessor).to receive(:get_refund).and_return(charge_refund_with(merchant_cents: 8_50, transfer_reversal: "trr_1"))

          purchase.handle_event_refund_updated!(build_external_event)

          expect(purchase.reload.refunds).to be_empty
          expect(seller_refund_debits).to be_empty
          expect(ErrorNotifier).to have_received(:notify).with(Charge::Refundable::EXTERNAL_REFUND_ALERT,
                                                               hash_including(transfer_outcome: :fee_refund_unpaired, recorded: false))
        end
      end

      it "does not reverse the transfer when a purchase on the charge cannot be booked" do
        create(:purchase_presentment, purchase:, presentment_currency: Currency::USD, presentment_price_cents: 10_00,
                                      presentment_gumroad_tax_cents: 0, presentment_total_cents: 10_00)
        purchase.association(:purchase_presentment).reset
        # A prior refund without a presentment snapshot leaves the remaining buyer-currency amount unknowable.
        create(:refund, purchase:, total_transaction_cents: 1_00, amount_cents: 1_00)
        expect(Stripe::Transfer).not_to receive(:create_reversal)

        purchase.handle_event_refund_updated!(build_external_event)

        expect(purchase.reload.refunds.count).to eq(1)
        expect(ErrorNotifier).to have_received(:notify).with(Charge::Refundable::EXTERNAL_REFUND_ALERT,
                                                             hash_including(blocked_purchase_ids: [purchase.id], transfer_outcome: nil, recorded: false))
      end

      it "leaves refunds the app created unchanged" do
        create(:refund, purchase:, processor_refund_id: refund_id, status: "pending")
        expect(Stripe::Transfer).not_to receive(:create_reversal)
        expect_any_instance_of(StripeChargeProcessor).not_to receive(:get_refund)

        purchase.handle_event_refund_updated!(build_external_event)

        expect(purchase.reload.refunds.sole.status).to eq("succeeded")
        expect(ErrorNotifier).not_to have_received(:notify)
      end
    end

    describe "refund created outside the app detector" do
      it "alerts when the refunded amount cannot be recorded" do
        expect(ErrorNotifier).to receive(:notify).with(Charge::Refundable::EXTERNAL_REFUND_ALERT,
                                                       hash_including(refunded_amount_cents: 11_00, recorded: false))

        purchase.handle_event_refund_updated!(build_event(refunded_amount_cents: 11_00))
      end

      it "alerts when a refund created outside the app is recorded on a platform charge" do
        stub_stripe_refund(presentment_cents: 10_00, currency: Currency::USD)
        expect(ErrorNotifier).to receive(:notify).with(Charge::Refundable::EXTERNAL_REFUND_ALERT,
                                                       hash_including(transfer_outcome: nil, refunded_purchase_ids: [purchase.id], recorded: true))

        purchase.handle_event_refund_updated!(build_event(refunded_amount_cents: 10_00))
      end
    end

    describe "combined charges with multiple purchases" do
      let(:purchase_one) { create(:purchase, price_cents: 10_00, total_transaction_cents: 10_00, is_part_of_combined_charge: true) }
      let(:purchase_two) { create(:purchase, price_cents: 5_00, total_transaction_cents: 5_00, is_part_of_combined_charge: true) }
      let!(:charge) do
        create(:charge,
               processor_transaction_id: "ch_refundable_#{SecureRandom.hex(6)}",
               amount_cents: 15_00,
               purchases: [purchase_one, purchase_two])
      end

      def build_charge_event(refunded_amount_cents:)
        event = ChargeEvent.new
        event.charge_processor_id = StripeChargeProcessor.charge_processor_id
        event.charge_id = charge.processor_transaction_id
        event.refund_id = "re_refundable_#{SecureRandom.hex(6)}"
        event.type = ChargeEvent::TYPE_CHARGE_REFUND_UPDATED
        event.extras = { refund_status: "succeeded", refunded_amount_cents:, refund_reason: nil }
        event
      end

      it "notifies and skips partial refunds instead of silently dropping them" do
        expect(ErrorNotifier).to receive(:notify).with(
          "Processor-initiated partial refund on a combined charge with multiple purchases cannot be attributed automatically",
          context: hash_including(refundable_type: "Charge",
                                  refundable_id: charge.id,
                                  refunded_amount_cents: 5_00,
                                  expected_refunded_amount_cents: 15_00)
        )
        expect_any_instance_of(StripeChargeProcessor).not_to receive(:get_refund)

        charge.handle_event_refund_updated!(build_charge_event(refunded_amount_cents: 5_00))

        expect(purchase_one.reload.refunds).to be_empty
        expect(purchase_two.reload.refunds).to be_empty
      end

      it "still records full refunds across all purchases" do
        stub_stripe_refund(presentment_cents: 15_00, currency: Currency::USD)

        charge.handle_event_refund_updated!(build_charge_event(refunded_amount_cents: 15_00))

        expect(purchase_one.reload.stripe_refunded?).to be(true)
        expect(purchase_two.reload.stripe_refunded?).to be(true)
      end
    end
  end
end
