# frozen_string_literal: true

require "spec_helper"

describe Checkout::PaymentMethodResolver do
  let(:seller) { create(:user) }

  def resolve(sellers: [seller], buyer_country: "US", **opts)
    described_class.new(sellers:, buyer_country:, **opts).resolve
  end

  describe "#resolve" do
    context "with a single-seller, one-time, platform-account cart" do
      it "is client-confirm eligible with no fallback reason" do
        resolution = resolve

        expect(resolution.client_confirm_eligible?).to be(true)
        expect(resolution.fallback_reason).to be_nil
      end

      it "scopes Elements to the platform account" do
        expect(resolve.stripe_connect_account_id).to be_nil
      end

      it "resolves the full inline dynamic method set as eligible" do
        expect(resolve.eligible_payment_method_types)
          .to eq(%w[card link klarna afterpay_clearpay affirm ideal bancontact cashapp us_bank_account])
      end

      it "enables the launched methods on Stripe for a US buyer, gating the rest behind later units" do
        resolution = resolve(buyer_country: "US")

        expect(resolution.payment_method_types).to eq(%w[card cashapp us_bank_account])
        # The launched set is always a subset of the eligible policy set.
        expect(resolution.eligible_payment_method_types).to include(*resolution.payment_method_types)
      end

      it "drops US-locked methods (Cash App/ACH) for a non-US buyer, leaving card only" do
        expect(resolve(buyer_country: "GB").payment_method_types).to eq(["card"])
      end

      it "drops US-locked methods when the buyer country is unknown, failing safe to card only" do
        expect(resolve(buyer_country: nil).payment_method_types).to eq(["card"])
      end

      context "when the seller has the Stripe Link flag enabled" do
        before { Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_LINK_FEATURE_NAME, seller) }

        it "launches Link alongside the US set, keeping card as the first Payment Element tab" do
          resolution = resolve

          expect(resolution.payment_method_types).to eq(%w[card link cashapp us_bank_account])
          expect(resolution.eligible_payment_method_types).to include(*resolution.payment_method_types)
        end

        it "keeps Link for a non-US buyer — the region gate only drops the US-locked methods" do
          expect(resolve(buyer_country: "GB").payment_method_types).to eq(%w[card link])
        end

        it "still gates the remaining redirect methods behind later units" do
          expect(resolve.payment_method_types).not_to include("klarna", "afterpay_clearpay", "affirm", "ideal", "bancontact")
        end
      end

      it "returns an explicit list of method-type strings, never Stripe's automatic_payment_methods shape" do
        expect(resolve.payment_method_types).to be_an(Array).and(all(be_a(String)))
      end

      context "with a PPP-discounted checkout (U13 method matrix)" do
        it "keeps card and the US-locked methods for a US buyer — verifiable + region-matched" do
          expect(resolve(ppp_discounted: true).payment_method_types).to eq(%w[card cashapp us_bank_account])
        end

        it "resolves card-only for a non-US PPP buyer (region-locked methods already dropped)" do
          expect(resolve(buyer_country: "BR", ppp_discounted: true).payment_method_types).to eq(["card"])
        end

        it "gates Link out — no Stripe-owned funding country to verify pre-charge" do
          Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_LINK_FEATURE_NAME, seller)

          expect(resolve(ppp_discounted: true).payment_method_types).to eq(%w[card cashapp us_bank_account])
          expect(resolve(ppp_discounted: false).payment_method_types).to eq(%w[card link cashapp us_bank_account])
        end

        it "logs the PPP gate input" do
          resolver = described_class.new(sellers: [seller], buyer_country: "US", ppp_discounted: true)
          allow(Rails.logger).to receive(:info)

          resolver.resolve

          expect(Rails.logger).to have_received(:info).with(a_string_matching(/ppp_discounted=true/))
        end
      end
    end

    context "with a recurring (subscription) lifecycle" do
      it "disables Afterpay/Clearpay and Affirm in the eligible set" do
        eligible = resolve(recurring: true).eligible_payment_method_types

        expect(eligible).not_to include("afterpay_clearpay", "affirm")
        expect(eligible).to include("card", "link")
      end

      it "stays on Lane A because subscription setup on the client-confirmed path is deferred" do
        resolution = resolve(recurring: true)

        expect(resolution.client_confirm_eligible?).to be(false)
        expect(resolution.fallback_reason).to eq("recurring_charge")
        expect(resolution.payment_method_types).to be_nil
      end
    end

    context "with a multi-seller cart" do
      let(:other_seller) { create(:user) }

      it "resolves to card + PayPal only and keeps the cart on Lane A" do
        resolution = resolve(sellers: [seller, other_seller])

        expect(resolution.client_confirm_eligible?).to be(false)
        expect(resolution.fallback_reason).to eq("multi_seller")
        expect(resolution.eligible_payment_method_types).to eq(%w[card paypal])
        expect(resolution.payment_method_types).to be_nil
        expect(resolution.stripe_connect_account_id).to be_nil
      end
    end

    context "with a connected-account (direct-charge) seller" do
      let(:seller) { create(:user, check_merchant_account_is_linked: true) }
      let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }

      it "is client-confirm eligible with Elements scoped to the connected account" do
        resolution = resolve

        expect(resolution.client_confirm_eligible?).to be(true)
        expect(resolution.fallback_reason).to be_nil
        expect(resolution.stripe_connect_account_id).to eq(connect_account.charge_processor_merchant_id)
        expect(resolution.payment_method_types).to eq(%w[card cashapp us_bank_account])
      end

      it "drops US-locked methods for a non-US buyer while keeping the connected-account scope" do
        resolution = resolve(buyer_country: "GB")

        expect(resolution.stripe_connect_account_id).to eq(connect_account.charge_processor_merchant_id)
        expect(resolution.payment_method_types).to eq(["card"])
      end

      it "falls back to Lane A when the connected account has no Charge Processor Merchant ID" do
        connect_account.update_column(:charge_processor_merchant_id, nil)

        resolution = resolve

        expect(resolution.client_confirm_eligible?).to be(false)
        expect(resolution.fallback_reason).to eq("direct_charge_account_unlinked")
        expect(resolution.stripe_connect_account_id).to be_nil
        expect(resolution.payment_method_types).to be_nil
      end
    end

    context "with a seller who has a connect account but charges routed to Gumroad" do
      let(:seller) { create(:user, check_merchant_account_is_linked: false) }
      before { create(:merchant_account_stripe_connect, user: seller) }

      it "is client-confirm eligible with platform-scoped Elements, matching the charge routing" do
        resolution = resolve

        expect(resolution.client_confirm_eligible?).to be(true)
        expect(resolution.stripe_connect_account_id).to be_nil
        expect(resolution.payment_method_types).to eq(%w[card cashapp us_bank_account])
      end
    end

    context "with a commission product" do
      it "keeps the cart on Lane A" do
        resolution = resolve(commission: true)

        expect(resolution.client_confirm_eligible?).to be(false)
        expect(resolution.fallback_reason).to eq("commission")
      end
    end

    context "with a future-charge setup cart (preorder / free trial)" do
      it "keeps the cart on Lane A" do
        resolution = resolve(setup_for_future: true)

        expect(resolution.client_confirm_eligible?).to be(false)
        expect(resolution.fallback_reason).to eq("setup_flow")
      end
    end

    it "logs the decision with enough detail to explain why a buyer saw a method" do
      resolver = described_class.new(sellers: [seller])
      allow(Rails.logger).to receive(:info)

      resolver.resolve

      expect(Rails.logger).to have_received(:info).with(
        a_string_matching(/client_confirm_eligible=true.*enabled=\["card"\].*launch_gated_out=.*stripe_connect_account_id=nil/)
      )
    end

    it "logs the buyer country and the US-locked method launch for a US buyer" do
      resolver = described_class.new(sellers: [seller], buyer_country: "US")
      allow(Rails.logger).to receive(:info)

      resolver.resolve

      expect(Rails.logger).to have_received(:info).with(
        a_string_matching(/buyer_country="US".*enabled=\["card", "cashapp", "us_bank_account"\]/)
      )
    end

    it "memoizes so the decision is logged once per resolver" do
      resolver = described_class.new(sellers: [seller])
      allow(Rails.logger).to receive(:info)

      2.times { resolver.resolve }

      expect(Rails.logger).to have_received(:info).with(a_string_matching(/\[Checkout::PaymentMethodResolver\]/)).once
    end
  end
end
