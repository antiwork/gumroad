# frozen_string_literal: true

require "spec_helper"

RSpec.describe ChargeProcessable do
  let(:test_class) do
    Class.new do
      include ChargeProcessable
      attr_accessor :charge_processor_id

      def initialize(charge_processor_id)
        @charge_processor_id = charge_processor_id
      end
    end
  end

  describe "#stripe_charge_processor?" do
    context "when charge_processor_id is stripe" do
      subject { test_class.new(StripeChargeProcessor.charge_processor_id) }

      it "returns true" do
        expect(subject.stripe_charge_processor?).to be true
      end
    end

    context "when charge_processor_id is not stripe" do
      subject { test_class.new(PaypalChargeProcessor.charge_processor_id) }

      it "returns false" do
        expect(subject.stripe_charge_processor?).to be false
      end
    end

    context "when charge_processor_id is nil" do
      subject { test_class.new(nil) }

      it "returns false" do
        expect(subject.stripe_charge_processor?).to be false
      end
    end
  end

  describe "#paypal_charge_processor?" do
    context "when charge_processor_id is paypal" do
      subject { test_class.new(PaypalChargeProcessor.charge_processor_id) }

      it "returns true" do
        expect(subject.paypal_charge_processor?).to be true
      end
    end

    context "when charge_processor_id is not paypal" do
      subject { test_class.new(StripeChargeProcessor.charge_processor_id) }

      it "returns false" do
        expect(subject.paypal_charge_processor?).to be false
      end
    end

    context "when charge_processor_id is nil" do
      subject { test_class.new(nil) }

      it "returns false" do
        expect(subject.paypal_charge_processor?).to be false
      end
    end
  end

  describe "#braintree_charge_processor?" do
    context "when charge_processor_id is braintree" do
      subject { test_class.new(BraintreeChargeProcessor.charge_processor_id) }

      it "returns true" do
        expect(subject.braintree_charge_processor?).to be true
      end
    end

    context "when charge_processor_id is not braintree" do
      subject { test_class.new(StripeChargeProcessor.charge_processor_id) }

      it "returns false" do
        expect(subject.braintree_charge_processor?).to be false
      end
    end

    context "when charge_processor_id is nil" do
      subject { test_class.new(nil) }

      it "returns false" do
        expect(subject.braintree_charge_processor?).to be false
      end
    end
  end
end
