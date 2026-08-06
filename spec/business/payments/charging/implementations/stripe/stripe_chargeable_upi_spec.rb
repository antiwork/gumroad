# frozen_string_literal: true

require "spec_helper"

describe StripeChargeableUpi do
  let(:merchant_account) do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                charge_processor_merchant_id: nil)
  end
  let(:chargeable) do
    described_class.new(
      merchant_account:,
      customer_id: "cus_upi",
      payment_method_id: "pm_upi",
      fingerprint: "pm_upi",
      stripe_payment_intent_id: "pi_upi_signup",
      stripe_account_id: nil,
      recurring_authorization_verified_at: Time.current,
      recurring_authorization_currency: Currency::INR,
      recurring_authorization_max_amount_cents: 200_000
    )
  end

  describe "#prepare!" do
    it "verifies that the UPI payment method remains attached to the stored customer" do
      expect(Stripe::PaymentMethod).to receive(:retrieve).with("pm_upi", {}).and_return(
        Stripe::PaymentMethod.construct_from(id: "pm_upi", type: "upi", customer: "cus_upi")
      )

      expect(chargeable.prepare!).to be(true)
      expect(chargeable.stripe_charge_params).to eq(customer: "cus_upi", payment_method: "pm_upi")
    end

    it "requests a payment-method update when the charged account changed" do
      seller = create(:user)
      merchant_account = create(:merchant_account_stripe_connect, user: seller)
      mismatched = described_class.new(
        merchant_account:,
        customer_id: "cus_upi",
        payment_method_id: "pm_upi",
        fingerprint: "pm_upi",
        stripe_payment_intent_id: "pi_upi_signup",
        stripe_account_id: nil,
        recurring_authorization_verified_at: Time.current,
        recurring_authorization_currency: Currency::INR,
        recurring_authorization_max_amount_cents: 200_000
      )
      allow(ErrorNotifier).to receive(:notify)
      expect(Stripe::PaymentMethod).not_to receive(:retrieve)

      expect { mismatched.prepare! }.to raise_error(ChargeProcessorCardError) do |error|
        expect(error.error_code).to eq(PurchaseErrorCode::UPI_RECURRING_AUTHORIZATION_REQUIRED)
      end
    end

    it "requests a payment-method update when the seller moved to destination charges" do
      seller = create(:user)
      destination_account = create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_upi_destination")
      changed_model = described_class.new(
        merchant_account: destination_account,
        customer_id: "cus_upi",
        payment_method_id: "pm_upi",
        fingerprint: "pm_upi",
        stripe_payment_intent_id: "pi_upi_signup",
        stripe_account_id: nil,
        recurring_authorization_verified_at: Time.current,
        recurring_authorization_currency: Currency::INR,
        recurring_authorization_max_amount_cents: 200_000
      )
      allow(ErrorNotifier).to receive(:notify)
      expect(Stripe::PaymentMethod).not_to receive(:retrieve)

      expect { changed_model.prepare! }.to raise_error(ChargeProcessorCardError) do |error|
        expect(error.error_code).to eq(PurchaseErrorCode::UPI_RECURRING_AUTHORIZATION_REQUIRED)
      end
    end

    it "requests a payment-method update when Stripe can no longer retrieve the saved payment method" do
      allow(Stripe::PaymentMethod).to receive(:retrieve)
        .and_raise(Stripe::InvalidRequestError.new("No such PaymentMethod", "payment_method"))
      expect(ErrorNotifier).to receive(:notify).with(
        "Saved UPI recurring payment method rejected before Stripe submit",
        reason: "payment method could not be retrieved"
      )

      expect { chargeable.prepare! }.to raise_error(ChargeProcessorCardError) do |error|
        expect(error.error_code).to eq(PurchaseErrorCode::UPI_RECURRING_AUTHORIZATION_REQUIRED)
      end
    end
  end
end
