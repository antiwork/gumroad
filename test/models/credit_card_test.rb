# frozen_string_literal: true

require "test_helper"

class CreditCardTest < ActiveSupport::TestCase
  self.described_class = CreditCard



  context_ CreditCard do
  context_ "after creating a credit card", :vcr do
      let(:chargeable) { build(:chargeable) }

  test "is valid" do
        credit_card = CreditCard.create(chargeable)
        expect(credit_card.valid?).to be(true)
      end

  test "has charge processor id matching the chargeable it wrapped" do
        credit_card = CreditCard.create(chargeable)
        expect(credit_card.charge_processor_id).to eq chargeable.charge_processor_id
      end

  test "has correct charge processor token" do
        expect(chargeable).to receive(:reusable_token_for!).with(StripeChargeProcessor.charge_processor_id, anything).once.ordered.and_return("reusable-token-stripe")
        expect(chargeable).to receive(:reusable_token_for!).with(BraintreeChargeProcessor.charge_processor_id, anything).once.ordered.and_return("reusable-token-braintree")
        expect(chargeable).to receive(:reusable_token_for!).with(PaypalChargeProcessor.charge_processor_id, anything).once.ordered.and_return("reusable-token-paypal")
        credit_card = CreditCard.create(chargeable)
        expect(credit_card.stripe_customer_id).to eq "reusable-token-stripe"
        expect(credit_card.braintree_customer_id).to eq "reusable-token-braintree"
        expect(credit_card.paypal_billing_agreement_id).to eq "reusable-token-paypal"
      end

  context_ "errors" do
  context_ "card declined" do
          let(:chargeable_decline) { build(:chargeable, card: StripePaymentMethodHelper.decline) }

  test "does not throw an exception" do
            expect { CreditCard.create(chargeable_decline) }.not_to raise_error
          end

  test "stores errors in 'errors'" do
            credit_card = CreditCard.create(chargeable_decline)
            expect(credit_card.errors).to be_present
            expect(credit_card.stripe_error_code).to be_present
          end
        end

  context_ "chard processor unavailable" do
          before do
            allow(chargeable).to receive(:reusable_token_for!).and_raise(ChargeProcessorUnavailableError)
          end

  test "does not throw an exception" do
            expect { CreditCard.create(chargeable) }.not_to raise_error
          end

  test "stores errors in 'errors'" do
            credit_card = CreditCard.create(chargeable)
            expect(credit_card.errors).to be_present
            expect(credit_card.error_code).to be_present
          end
        end

  context_ "chard processor invalid request" do
          before do
            allow(chargeable).to receive(:reusable_token_for!).and_raise(ChargeProcessorInvalidRequestError)
          end

  test "does not throw an exception" do
            expect { CreditCard.create(chargeable) }.not_to raise_error
          end

  test "stores errors in 'errors'" do
            credit_card = CreditCard.create(chargeable)
            expect(credit_card.errors).to be_present
            expect(credit_card.error_code).to be_present
          end
        end
      end

  context_ "#charge_processor_unavailable_error" do
  test "returns STRIPE_UNAVAILABLE error if charge_processor_id is nil" do
          credit_card = build(:credit_card, charge_processor_id: nil)
          expect(credit_card.send(:charge_processor_unavailable_error)).to eq PurchaseErrorCode::STRIPE_UNAVAILABLE
        end

  test "returns STRIPE_UNAVAILABLE error if charge_processor_id is Stripe" do
          credit_card = create(:credit_card, charge_processor_id: StripeChargeProcessor.charge_processor_id)
          expect(credit_card.send(:charge_processor_unavailable_error)).to eq PurchaseErrorCode::STRIPE_UNAVAILABLE
        end

  test "returns PAYPAL_UNAVAILABLE error if charge_processor_id is Paypal" do
          credit_card = build(:credit_card, charge_processor_id: PaypalChargeProcessor.charge_processor_id)
          expect(credit_card.send(:charge_processor_unavailable_error)).to eq PurchaseErrorCode::PAYPAL_UNAVAILABLE
        end

  test "returns PAYPAL_UNAVAILABLE error if charge_processor_id is Braintree" do
          credit_card = build(:credit_card, charge_processor_id: BraintreeChargeProcessor.charge_processor_id)
          expect(credit_card.send(:charge_processor_unavailable_error)).to eq PurchaseErrorCode::PAYPAL_UNAVAILABLE
        end
      end
    end

  context_ "#create", :vcr do
      before do
        allow_any_instance_of(StripeChargeablePaymentMethod).to receive(:stripe_setup_intent_id).and_return("seti_1234567890")
        allow_any_instance_of(StripeChargeablePaymentMethod).to receive(:stripe_payment_intent_id).and_return("pi_1234567890")
      end

  context_ "when card country is India and processor is Stripe" do
        let!(:chargeable) { create(:chargeable, card: StripePaymentMethodHelper.success_indian_card_mandate) }

  test "saves stripe_setup_intent_id if it present on the chargeable" do
          credit_card = CreditCard.create(chargeable)
          expect(credit_card.stripe_setup_intent_id).to eq "seti_1234567890"
        end

  test "saves stripe_payment_intent_id if it present on the chargeable" do
          credit_card = CreditCard.create(chargeable)
          expect(credit_card.stripe_payment_intent_id).to eq "pi_1234567890"
        end
      end

  context_ "when card country is not India and processor is Stripe" do
        let!(:chargeable) { create(:chargeable, card: StripePaymentMethodHelper.success) }

  test "does not save stripe_setup_intent_id even if it present on the chargeable" do
          credit_card = CreditCard.create(chargeable)
          expect(credit_card.stripe_setup_intent_id).to be nil
        end

  test "does not save stripe_payment_intent_id even if it present on the chargeable" do
          credit_card = CreditCard.create(chargeable)
          expect(credit_card.stripe_payment_intent_id).to be nil
        end
      end
    end
  end
end
