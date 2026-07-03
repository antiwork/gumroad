# frozen_string_literal: true

require "spec_helper"

describe Charge::Refundable do
  describe "#handle_event_refund_updated!" do
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
