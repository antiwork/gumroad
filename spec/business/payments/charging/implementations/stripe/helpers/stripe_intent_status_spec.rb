# frozen_string_literal: true

require "spec_helper"

describe StripeIntentStatus do
  describe ".client_handled_next_action?" do
    it "accepts the method-specific browser-handled action types regardless of the method list" do
      expect(described_class.client_handled_next_action?("cashapp_handle_redirect_or_display_qr_code", ["card"])).to eq(true)
    end

    it "accepts Alipay's own redirect action type — Stripe.js owns that redirect, so an abandoned one on the return page must not alert" do
      expect(described_class.client_handled_next_action?("alipay_handle_redirect", ["card"])).to eq(true)
    end

    it "accepts UPI's browser-owned redirect or QR action" do
      expect(described_class.client_handled_next_action?("upi_handle_redirect_or_display_qr_code", %w[card upi])).to eq(true)
    end

    it "rejects non-redirect action types even when a client-redirect method is offered" do
      expect(described_class.client_handled_next_action?("boleto_display_details", %w[card klarna])).to eq(false)
    end

    context "for redirect_to_url" do
      it "accepts when the attempted method is a client-redirect method" do
        expect(described_class.client_handled_next_action?("redirect_to_url", %w[card klarna], payment_method_type: "klarna")).to eq(true)
      end

      it "rejects when the attempted method is card, even though the intent's menu offers a client-redirect method — a stray redirect on the card path must keep alerting" do
        expect(described_class.client_handled_next_action?("redirect_to_url", %w[card klarna], payment_method_type: "card")).to eq(false)
      end

      it "falls back to the offered menu when the attempted method is unknown" do
        expect(described_class.client_handled_next_action?("redirect_to_url", %w[card klarna])).to eq(true)
        expect(described_class.client_handled_next_action?("redirect_to_url", %w[card link])).to eq(false)
      end

      it "accepts when the attempted method is Alipay — Stripe surfaces either the generic redirect action or alipay_handle_redirect depending on the confirm" do
        expect(described_class.client_handled_next_action?("redirect_to_url", %w[card alipay], payment_method_type: "alipay")).to eq(true)
      end

      it "keeps alerting when the attempted-method lookup FAILED — a lookup failure is not evidence the redirect was client-owned, and the menu fallback would swallow it (cashapp is on nearly every US menu)" do
        expect(described_class.client_handled_next_action?("redirect_to_url", %w[card klarna cashapp], payment_method_type: described_class::PAYMENT_METHOD_LOOKUP_FAILED)).to eq(false)
      end
    end
  end

  describe ".attempted_payment_method_type" do
    it "reads the type from an expanded payment_method object without calling the API" do
      intent = Stripe::StripeObject.construct_from(payment_method: { type: "klarna" })

      expect(Stripe::PaymentMethod).not_to receive(:retrieve)
      expect(described_class.attempted_payment_method_type(intent)).to eq("klarna")
    end

    it "retrieves the payment method when the intent carries only the ID string" do
      intent = Stripe::StripeObject.construct_from(payment_method: "pm_123")
      expect(Stripe::PaymentMethod).to receive(:retrieve).with("pm_123", {})
        .and_return(Stripe::StripeObject.construct_from(id: "pm_123", type: "ideal"))

      expect(described_class.attempted_payment_method_type(intent)).to eq("ideal")
    end

    it "scopes the retrieve to the connected account when given one" do
      intent = Stripe::StripeObject.construct_from(payment_method: "pm_123")
      expect(Stripe::PaymentMethod).to receive(:retrieve).with("pm_123", { stripe_account: "acct_1" })
        .and_return(Stripe::StripeObject.construct_from(id: "pm_123", type: "card"))

      expect(described_class.attempted_payment_method_type(intent, stripe_account: "acct_1")).to eq("card")
    end

    it "returns the lookup-failed sentinel (never nil) when the retrieve fails, so the redirect alert stays alive instead of degrading to the menu fallback, and reports the failure" do
      intent = Stripe::StripeObject.construct_from(payment_method: "pm_123")
      error = Stripe::InvalidRequestError.new("nope", "payment_method")
      expect(Stripe::PaymentMethod).to receive(:retrieve).and_raise(error)
      expect(ErrorNotifier).to receive(:notify).with(error, payment_method_id: "pm_123", stripe_account: nil)

      expect(described_class.attempted_payment_method_type(intent)).to eq(described_class::PAYMENT_METHOD_LOOKUP_FAILED)
    end

    it "returns nil when no payment method is attached" do
      intent = Stripe::StripeObject.construct_from(payment_method: nil)

      expect(described_class.attempted_payment_method_type(intent)).to be_nil
    end
  end
end
