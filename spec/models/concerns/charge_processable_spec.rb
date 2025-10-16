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

  # Test with actual models that include ChargeProcessable
  describe "integration with Purchase model" do
    let(:purchase) { build(:purchase) }

    it "includes ChargeProcessable" do
      expect(purchase.class.included_modules).to include(ChargeProcessable)
    end

    it "responds to stripe_charge_processor?" do
      expect(purchase).to respond_to(:stripe_charge_processor?)
    end

    it "responds to paypal_charge_processor?" do
      expect(purchase).to respond_to(:paypal_charge_processor?)
    end

    it "responds to braintree_charge_processor?" do
      expect(purchase).to respond_to(:braintree_charge_processor?)
    end
  end

  describe "integration with MerchantAccount model" do
    let(:merchant_account) { build(:merchant_account) }

    it "includes ChargeProcessable" do
      expect(merchant_account.class.included_modules).to include(ChargeProcessable)
    end

    it "responds to stripe_charge_processor?" do
      expect(merchant_account).to respond_to(:stripe_charge_processor?)
    end

    it "responds to paypal_charge_processor?" do
      expect(merchant_account).to respond_to(:paypal_charge_processor?)
    end

    it "responds to braintree_charge_processor?" do
      expect(merchant_account).to respond_to(:braintree_charge_processor?)
    end
  end

  describe "integration with CreditCard model" do
    let(:credit_card) { build(:credit_card) }

    before do
      mock = double("Stripe::PaymentMethod")
      customer_mock = double("Stripe::Customer")
      allow(customer_mock).to receive(:id).and_return("stripe-customer-id")
      card_mock = double("Stripe::Card")
      allow(card_mock).to receive('[]').with(:brand).and_return("visa")
      allow(card_mock).to receive('[]').with(:fingerprint).and_return("fingerprint")
      allow(card_mock).to receive('[]').with(:last4).and_return("last4")
      allow(card_mock).to receive('[]').with(:exp_month).and_return(12)
      allow(card_mock).to receive('[]').with(:exp_year).and_return(2023)
      allow(card_mock).to receive('[]').with(:funding).and_return("credit")
      allow(card_mock).to receive('[]').with(:country).and_return("US")
      allow(mock).to receive(:id).and_return("stripe-payment-method-id")
      allow(mock).to receive(:customer).and_return(customer_mock)
      allow(mock).to receive(:card).and_return(card_mock)
      allow(Stripe::PaymentMethod).to receive(:create).and_return(mock)
      allow(Stripe::PaymentMethod).to receive(:retrieve).and_return(mock)
    end

    it "includes ChargeProcessable" do
      expect(credit_card.class.included_modules).to include(ChargeProcessable)
    end

    it "responds to stripe_charge_processor?" do
      expect(credit_card).to respond_to(:stripe_charge_processor?)
    end

    it "responds to paypal_charge_processor?" do
      expect(credit_card).to respond_to(:paypal_charge_processor?)
    end

    it "responds to braintree_charge_processor?" do
      expect(credit_card).to respond_to(:braintree_charge_processor?)
    end
  end
end
