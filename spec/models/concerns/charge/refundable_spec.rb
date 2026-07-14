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
