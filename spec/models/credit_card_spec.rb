# frozen_string_literal: true

require "spec_helper"

describe CreditCard do
  describe "UPI classification" do
    let(:credit_card) do
      described_class.new(
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        stripe_customer_id: "cus_one_time_upi",
        stripe_fingerprint: "upi_fingerprint",
        visual: "UPI",
        card_type: CardType::UPI,
        card_country: Compliance::Countries::IND.alpha2
      )
    end

    it "does not require recurring authorization fields for one-time UPI" do
      expect(credit_card).to be_upi
      expect(credit_card).not_to be_recurring_upi
      expect(credit_card).to be_valid
    end

    it "does not reconstruct one-time UPI as an Autopay chargeable" do
      expect(StripeChargeableUpi).not_to receive(:new)

      credit_card.to_chargeable
    end
  end

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
          expect(credit_card.error_code).to eq PurchaseErrorCode::PROCESSOR_INVALID_REQUEST
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

  describe ".create_from_client_confirmed_intent!" do
    let(:payment_intent) do
      Stripe::PaymentIntent.construct_from(
        id: "pi_upi_signup",
        customer: "cus_upi_signup",
        payment_method: "pm_upi_signup",
        status: StripeIntentStatus::SUCCESS,
        setup_future_usage: "off_session",
        currency: Currency::INR,
        metadata: {
          StripeChargeProcessor::UPI_RECURRING_MAX_AMOUNT_METADATA_KEY => "125000"
        }
      )
    end
    let(:processor_charge) do
      BaseProcessorCharge.new.tap do |charge|
        charge.charge_processor_id = StripeChargeProcessor.charge_processor_id
        charge.payment_method_type = "upi"
        charge.card_instance_id = "pm_upi_signup"
        charge.card_fingerprint = "pm_upi_signup"
        charge.card_type = CardType::UPI
      end
    end

    it "persists the reusable UPI authorization without card expiry or a fabricated mandate id" do
      credit_card = described_class.create_from_client_confirmed_intent!(
        payment_intent:,
        processor_charge:,
        merchant_account: nil
      )

      expect(credit_card).to be_persisted
      expect(credit_card).to be_upi
      expect(credit_card).to be_recurring_upi
      expect(credit_card).not_to be_requires_mandate
      expect(credit_card).to have_attributes(
        stripe_customer_id: "cus_upi_signup",
        processor_payment_method_id: "pm_upi_signup",
        stripe_account_id: nil,
        recurring_authorization_currency: Currency::INR,
        recurring_authorization_max_amount_cents: 125_000,
        expiry_month: nil,
        expiry_year: nil,
        stripe_payment_intent_id: "pi_upi_signup"
      )
      expect(credit_card.recurring_authorization_verified_at).to be_present
      expect(credit_card.json_data).not_to have_key("stripe_mandate_id")
      expect(credit_card.to_chargeable.get_chargeable_for(StripeChargeProcessor.charge_processor_id)).to be_a(StripeChargeableUpi)
    end

    it "rejects an intent that did not verify off-session reuse" do
      payment_intent.setup_future_usage = nil

      expect do
        described_class.create_from_client_confirmed_intent!(
          payment_intent:,
          processor_charge:,
          merchant_account: nil
        )
      end.to raise_error(ArgumentError, /did not verify off-session reuse/)
    end

    it "rejects an intent that did not complete successfully" do
      payment_intent.status = StripeIntentStatus::PROCESSING

      expect do
        described_class.create_from_client_confirmed_intent!(
          payment_intent:,
          processor_charge:,
          merchant_account: nil
        )
      end.to raise_error(ArgumentError, /did not succeed/)
    end

    it "rejects a UPI intent that did not preserve the server-authorized maximum" do
      payment_intent.metadata = {}

      expect do
        described_class.create_from_client_confirmed_intent!(
          payment_intent:,
          processor_charge:,
          merchant_account: nil
        )
      end.to raise_error(ArgumentError, /did not preserve a valid maximum UPI debit/)
    end

    it "rejects a UPI intent whose persisted maximum exceeds Stripe's recurring limit" do
      payment_intent.metadata = {
        StripeChargeProcessor::UPI_RECURRING_MAX_AMOUNT_METADATA_KEY =>
          (Checkout::PaymentMethodResolver::UPI_RECURRING_MAX_INR_CENTS + 1).to_s
      }

      expect do
        described_class.create_from_client_confirmed_intent!(
          payment_intent:,
          processor_charge:,
          merchant_account: nil
        )
      end.to raise_error(ArgumentError, /did not preserve a valid maximum UPI debit/)
    end

    it "rejects a UPI intent outside INR even if it otherwise succeeded" do
      payment_intent.currency = Currency::USD

      expect do
        described_class.create_from_client_confirmed_intent!(
          payment_intent:,
          processor_charge:,
          merchant_account: nil
        )
      end.to raise_error(ArgumentError, /did not use INR/)
    end

    it "preserves the saved Indian-card mandate source when card was selected" do
      card_payment_intent = Stripe::PaymentIntent.construct_from(
        payment_intent.to_hash.merge(id: "pi_card_signup", payment_method: "pm_card_signup")
      )
      processor_charge.payment_method_type = "card"
      processor_charge.card_instance_id = "pm_card_signup"
      processor_charge.card_fingerprint = "card_fingerprint"
      processor_charge.card_type = CardType::VISA
      processor_charge.card_country = Compliance::Countries::IND.alpha2
      processor_charge.card_last4 = "4242"
      processor_charge.card_number_length = 16
      processor_charge.card_expiry_month = 12
      processor_charge.card_expiry_year = 2030

      credit_card = described_class.create_from_client_confirmed_intent!(
        payment_intent: card_payment_intent,
        processor_charge:,
        merchant_account: nil
      )

      expect(credit_card).not_to be_upi
      expect(credit_card).to be_requires_mandate
      expect(credit_card).to have_attributes(
        processor_payment_method_id: "pm_card_signup",
        card_country: Compliance::Countries::IND.alpha2,
        expiry_month: 12,
        expiry_year: 2030,
        stripe_payment_intent_id: "pi_card_signup"
      )
    end
  end
end
