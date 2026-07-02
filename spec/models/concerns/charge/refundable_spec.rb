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

      it "does not treat the canonical USD amount as a full refund" do
        purchase.handle_event_refund_updated!(build_event(refunded_amount_cents: 10_00))

        expect(purchase.reload.refunds).to be_empty
        expect(purchase.stripe_refunded?).to be(false)
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
    end
  end
end
