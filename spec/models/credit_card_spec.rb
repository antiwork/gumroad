# frozen_string_literal: true

require "spec_helper"

describe CreditCard do
  describe "after creating a credit card", :vcr do
    let(:chargeable) { build(:chargeable) }

    it "is valid" do
      credit_card = CreditCard.create(chargeable)
      expect(credit_card.valid?).to be(true)
    end

    it "has charge processor id matching the chargeable it wrapped" do
      credit_card = CreditCard.create(chargeable)
      expect(credit_card.charge_processor_id).to eq chargeable.charge_processor_id
    end

    it "has correct charge processor token" do
      expect(chargeable).to receive(:reusable_token_for!).with(StripeChargeProcessor.charge_processor_id, anything).once.ordered.and_return("reusable-token-stripe")
      expect(chargeable).to receive(:reusable_token_for!).with(BraintreeChargeProcessor.charge_processor_id, anything).once.ordered.and_return("reusable-token-braintree")
      expect(chargeable).to receive(:reusable_token_for!).with(PaypalChargeProcessor.charge_processor_id, anything).once.ordered.and_return("reusable-token-paypal")
      credit_card = CreditCard.create(chargeable)
      expect(credit_card.stripe_customer_id).to eq "reusable-token-stripe"
      expect(credit_card.braintree_customer_id).to eq "reusable-token-braintree"
      expect(credit_card.paypal_billing_agreement_id).to eq "reusable-token-paypal"
    end

    describe "errors" do
      describe "card declined" do
        let(:chargeable_decline) { build(:chargeable, card: StripePaymentMethodHelper.decline) }

        it "does not throw an exception" do
          expect { CreditCard.create(chargeable_decline) }.to_not raise_error
        end

        it "stores errors in 'errors'" do
          credit_card = CreditCard.create(chargeable_decline)
          expect(credit_card.errors).to be_present
          expect(credit_card.stripe_error_code).to be_present
        end
      end

      describe "chard processor unavailable" do
        before do
          allow(chargeable).to receive(:reusable_token_for!).and_raise(ChargeProcessorUnavailableError)
        end

        it "does not throw an exception" do
          expect { CreditCard.create(chargeable) }.to_not raise_error
        end

        it "stores errors in 'errors'" do
          credit_card = CreditCard.create(chargeable)
          expect(credit_card.errors).to be_present
          expect(credit_card.error_code).to be_present
        end
      end

      describe "chard processor invalid request" do
        before do
          allow(chargeable).to receive(:reusable_token_for!).and_raise(ChargeProcessorInvalidRequestError)
        end

        it "does not throw an exception" do
          expect { CreditCard.create(chargeable) }.to_not raise_error
        end

        it "stores errors in 'errors'" do
          credit_card = CreditCard.create(chargeable)
          expect(credit_card.errors).to be_present
          expect(credit_card.error_code).to be_present
        end
      end
    end

    describe "#charge_processor_unavailable_error" do
      it "returns STRIPE_UNAVAILABLE error if charge_processor_id is nil" do
        credit_card = build(:credit_card, charge_processor_id: nil)
        expect(credit_card.send(:charge_processor_unavailable_error)).to eq PurchaseErrorCode::STRIPE_UNAVAILABLE
      end

      it "returns STRIPE_UNAVAILABLE error if charge_processor_id is Stripe" do
        credit_card = create(:credit_card, charge_processor_id: StripeChargeProcessor.charge_processor_id)
        expect(credit_card.send(:charge_processor_unavailable_error)).to eq PurchaseErrorCode::STRIPE_UNAVAILABLE
      end

      it "returns PAYPAL_UNAVAILABLE error if charge_processor_id is Paypal" do
        credit_card = build(:credit_card, charge_processor_id: PaypalChargeProcessor.charge_processor_id)
        expect(credit_card.send(:charge_processor_unavailable_error)).to eq PurchaseErrorCode::PAYPAL_UNAVAILABLE
      end

      it "returns PAYPAL_UNAVAILABLE error if charge_processor_id is Braintree" do
        credit_card = build(:credit_card, charge_processor_id: BraintreeChargeProcessor.charge_processor_id)
        expect(credit_card.send(:charge_processor_unavailable_error)).to eq PurchaseErrorCode::PAYPAL_UNAVAILABLE
      end
    end
  end

  describe "#create", :vcr do
    before do
      allow_any_instance_of(StripeChargeablePaymentMethod).to receive(:stripe_setup_intent_id).and_return("seti_1234567890")
      allow_any_instance_of(StripeChargeablePaymentMethod).to receive(:stripe_payment_intent_id).and_return("pi_1234567890")
    end

    context "when card country is India and processor is Stripe" do
      let!(:chargeable) { create(:chargeable, card: StripePaymentMethodHelper.success_indian_card_mandate) }

      it "saves stripe_setup_intent_id if it present on the chargeable" do
        credit_card = CreditCard.create(chargeable)
        expect(credit_card.stripe_setup_intent_id).to eq "seti_1234567890"
      end

      it "saves stripe_payment_intent_id if it present on the chargeable" do
        credit_card = CreditCard.create(chargeable)
        expect(credit_card.stripe_payment_intent_id).to eq "pi_1234567890"
      end
    end

    context "when card country is not India and processor is Stripe" do
      let!(:chargeable) { create(:chargeable, card: StripePaymentMethodHelper.success) }

      it "does not save stripe_setup_intent_id even if it present on the chargeable" do
        credit_card = CreditCard.create(chargeable)
        expect(credit_card.stripe_setup_intent_id).to be nil
      end

      it "does not save stripe_payment_intent_id even if it present on the chargeable" do
        credit_card = CreditCard.create(chargeable)
        expect(credit_card.stripe_payment_intent_id).to be nil
      end
    end
  end
end
