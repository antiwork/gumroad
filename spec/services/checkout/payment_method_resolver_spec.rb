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

        expect(resolution.payment_method_types).to eq(%w[card link cashapp us_bank_account])
        # The launched set is always a subset of the eligible policy set.
        expect(resolution.eligible_payment_method_types).to include(*resolution.payment_method_types)
      end

      it "drops US-locked methods (Cash App/ACH) for a non-US buyer, keeping card and Link" do
        expect(resolve(buyer_country: "GB").payment_method_types).to eq(%w[card link])
      end

      it "drops US-locked methods when the buyer country is unknown, failing safe to card and Link" do
        expect(resolve(buyer_country: nil).payment_method_types).to eq(%w[card link])
      end

      it "launches Link with no per-seller flag — it auto-enables with the Payment Element" do
        expect(resolve.payment_method_types).to include("link")
      end

      it "still gates the remaining redirect methods behind later units" do
        expect(resolve.payment_method_types).not_to include("klarna", "afterpay_clearpay", "affirm", "ideal", "bancontact")
      end

      context "with the internal buyer-currency flags enabled in Stripe test mode" do
        before do
          allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
          Feature.activate_user(:buyer_currency_charging, seller)
          Feature.activate_user(:buyer_local_currency, seller)
        end

        it "surfaces the EUR forced-currency methods for manual presentment QA when the cart is priced in EUR" do
          expect(resolve(cart_product_currency: "eur").payment_method_types).to include("ideal", "bancontact")
        end

        it "keeps them off a USD-priced cart — Stripe rejects an element/intent listing EUR-only methods in USD" do
          expect(resolve(cart_product_currency: "usd").payment_method_types).not_to include("ideal", "bancontact")
        end

        it "keeps them off when the cart currency is unknown (multi-item carts pass nil), failing safe" do
          expect(resolve(cart_product_currency: nil).payment_method_types).not_to include("ideal", "bancontact")
        end

        it "keeps them out when the buyer-currency charging flag is off" do
          Feature.deactivate_user(:buyer_currency_charging, seller)

          expect(resolve(cart_product_currency: "eur").payment_method_types).not_to include("ideal", "bancontact")
        end

        it "keeps them out of live mode — this is a test-mode-only QA surface" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)

          expect(resolve(cart_product_currency: "eur").payment_method_types).not_to include("ideal", "bancontact")
        end

        it "keeps them out when the seller opted out of buyer-local currency" do
          seller.update!(disable_buyer_local_currency: true)

          expect(resolve(cart_product_currency: "eur").payment_method_types).not_to include("ideal", "bancontact")
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
      end

      context "when the account has no availability snapshot yet" do
        it "fails safe to card only for a US buyer and enqueues a background refresh — even Link waits for the snapshot, since link_payments is absent on many connected accounts and listing it fails the intent create" do
          expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).to receive(:perform_async).with(connect_account.id)

          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card])
        end

        it "resolves card only for a non-US buyer too" do
          expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).to receive(:perform_async).with(connect_account.id)

          expect(resolve(buyer_country: "GB").payment_method_types).to eq(%w[card])
        end

        it "keeps the checkout render alive when the refresh enqueue itself fails — the refresh is best-effort" do
          expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).to receive(:perform_async).and_raise(RedisClient::CannotConnectError)

          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card])
        end
      end

      context "when the snapshot is older than SNAPSHOT_MAX_AGE" do
        before do
          connect_account.update!(stripe_capabilities_snapshot: {
                                    "capabilities" => { "link_payments" => "active", "cashapp_payments" => "active", "us_bank_account_ach_payments" => "active" },
                                    "refreshed_at" => (StripeConnectPaymentMethodAvailabilityService::SNAPSHOT_MAX_AGE + 1.hour).ago.iso8601,
                                  })
        end

        it "still uses the stale snapshot (checkout never blocks) but enqueues a background re-fetch — the self-heal for webhooks dropped by the worker's until_executed lock" do
          expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).to receive(:perform_async).with(connect_account.id)

          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card link cashapp us_bank_account])
        end
      end

      context "when the snapshot says the account accepts both US-locked methods" do
        before do
          connect_account.update!(stripe_capabilities_snapshot: {
                                    "capabilities" => { "link_payments" => "active", "cashapp_payments" => "active", "us_bank_account_ach_payments" => "active" },
                                    "refreshed_at" => Time.current.iso8601,
                                  })
        end

        it "offers them to a US buyer without enqueueing a refresh" do
          expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).not_to receive(:perform_async)

          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card link cashapp us_bank_account])
        end

        it "still drops them for a non-US buyer — our region policy applies regardless of the account's capabilities" do
          expect(resolve(buyer_country: "GB").payment_method_types).to eq(%w[card link])
        end
      end

      context "when the snapshot says the account accepts only Cash App Pay" do
        before do
          connect_account.update!(stripe_capabilities_snapshot: {
                                    "capabilities" => { "link_payments" => "active", "cashapp_payments" => "active", "us_bank_account_ach_payments" => "inactive" },
                                    "refreshed_at" => Time.current.iso8601,
                                  })
        end

        it "offers exactly the accepted method to a US buyer" do
          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card link cashapp])
        end
      end

      context "when the snapshot says the account's Link capability is not active" do
        before do
          connect_account.update!(stripe_capabilities_snapshot: {
                                    "capabilities" => { "cashapp_payments" => "active" },
                                    "refreshed_at" => Time.current.iso8601,
                                  })
        end

        it "drops Link too — the capability intersection covers every method, not just the US-locked pair" do
          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card cashapp])
        end
      end

      context "when the snapshot says the account accepts neither US-locked method" do
        before do
          connect_account.update!(stripe_capabilities_snapshot: {
                                    "capabilities" => { "card_payments" => "active", "link_payments" => "active" },
                                    "refreshed_at" => Time.current.iso8601,
                                  })
        end

        it "resolves card and Link for a US buyer without enqueueing a refresh — the empty snapshot is an answer, not a miss" do
          expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).not_to receive(:perform_async)

          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card link])
        end

        it "resolves card-only for a US PPP buyer — Link is PPP-gated and the account accepts no US-locked methods" do
          expect(resolve(buyer_country: "US", ppp_discounted: true).payment_method_types).to eq(["card"])
        end
      end

      it "drops US-locked methods for a non-US buyer while keeping the connected-account scope" do
        connect_account.update!(stripe_capabilities_snapshot: {
                                  "capabilities" => { "link_payments" => "active", "cashapp_payments" => "active", "us_bank_account_ach_payments" => "active" },
                                  "refreshed_at" => Time.current.iso8601,
                                })

        resolution = resolve(buyer_country: "GB")

        expect(resolution.stripe_connect_account_id).to eq(connect_account.charge_processor_merchant_id)
        expect(resolution.payment_method_types).to eq(%w[card link])
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
        expect(resolution.payment_method_types).to eq(%w[card link cashapp us_bank_account])
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
        a_string_matching(/client_confirm_eligible=true.*enabled=\["card", "link"\].*launch_gated_out=.*stripe_connect_account_id=nil/)
      )
    end

    it "logs the buyer country and the US-locked method launch for a US buyer" do
      resolver = described_class.new(sellers: [seller], buyer_country: "US")
      allow(Rails.logger).to receive(:info)

      resolver.resolve

      expect(Rails.logger).to have_received(:info).with(
        a_string_matching(/buyer_country="US".*enabled=\["card", "link", "cashapp", "us_bank_account"\]/)
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
