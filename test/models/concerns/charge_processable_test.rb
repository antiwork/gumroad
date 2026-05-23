# frozen_string_literal: true

require "test_helper"

class ChargeProcessableTest < ActiveSupport::TestCase
  self.described_class = ChargeProcessable



  context_ ChargeProcessable do
    let(:test_class) do
      Class.new do
        include ChargeProcessable
        attr_accessor :charge_processor_id

        def initialize(charge_processor_id)
          @charge_processor_id = charge_processor_id
        end
      end
    end

  context_ "#stripe_charge_processor?" do
  context_ "when charge_processor_id is stripe" do
        subject { test_class.new(StripeChargeProcessor.charge_processor_id) }

  test "returns true" do
          expect(subject.stripe_charge_processor?).to be true
        end
      end

  context_ "when charge_processor_id is not stripe" do
        subject { test_class.new(PaypalChargeProcessor.charge_processor_id) }

  test "returns false" do
          expect(subject.stripe_charge_processor?).to be false
        end
      end

  context_ "when charge_processor_id is nil" do
        subject { test_class.new(nil) }

  test "returns false" do
          expect(subject.stripe_charge_processor?).to be false
        end
      end
    end

  context_ "#paypal_charge_processor?" do
  context_ "when charge_processor_id is paypal" do
        subject { test_class.new(PaypalChargeProcessor.charge_processor_id) }

  test "returns true" do
          expect(subject.paypal_charge_processor?).to be true
        end
      end

  context_ "when charge_processor_id is not paypal" do
        subject { test_class.new(StripeChargeProcessor.charge_processor_id) }

  test "returns false" do
          expect(subject.paypal_charge_processor?).to be false
        end
      end

  context_ "when charge_processor_id is nil" do
        subject { test_class.new(nil) }

  test "returns false" do
          expect(subject.paypal_charge_processor?).to be false
        end
      end
    end

  context_ "#braintree_charge_processor?" do
  context_ "when charge_processor_id is braintree" do
        subject { test_class.new(BraintreeChargeProcessor.charge_processor_id) }

  test "returns true" do
          expect(subject.braintree_charge_processor?).to be true
        end
      end

  context_ "when charge_processor_id is not braintree" do
        subject { test_class.new(StripeChargeProcessor.charge_processor_id) }

  test "returns false" do
          expect(subject.braintree_charge_processor?).to be false
        end
      end

  context_ "when charge_processor_id is nil" do
        subject { test_class.new(nil) }

  test "returns false" do
          expect(subject.braintree_charge_processor?).to be false
        end
      end
    end
  end
end
