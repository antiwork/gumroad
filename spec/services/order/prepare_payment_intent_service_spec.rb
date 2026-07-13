# frozen_string_literal: true

require "spec_helper"

describe Order::PreparePaymentIntentService, :vcr do
  include StripeMerchantAccountHelper

  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 10_00) }
  let(:browser_guid) { SecureRandom.uuid }

  let(:common_params) do
    {
      email: "buyer@example.com",
      cc_zipcode: "12345",
      purchase: {
        full_name: "Edgar Gumstein", street_address: "123 Gum Road",
        country: "US", state: "CA", city: "San Francisco", zip_code: "94117"
      },
      browser_guid:,
      ip_address: "0.0.0.0",
      session_id: "a107d0b7ab5ab3c1eeb7d3aaf9792977",
      is_mobile: false,
    }
  end

  let(:line_item) { { uid: "unique-id-0", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 } }

  def confirmation_token_id(payment_method: "pm_card_visa")
    response = Stripe.raw_request(:post, "/v1/test_helpers/confirmation_tokens", { payment_method: })
    Stripe.deserialize(response.http_body).id
  end

  def build_order(line_item_overrides: {})
    params = { line_items: [line_item.merge(line_item_overrides)] }.merge(common_params)
    order, = Order::CreateService.new(params:).perform
    [order, params]
  end

  describe "#perform" do
    context "with a single-seller card cart" do
      before { create(:merchant_account, user: seller, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id) }

      it "creates an unconfirmed PaymentIntent, persists the mapping, and returns a confirmation envelope without charging" do
        order, params = build_order
        token = confirmation_token_id
        create_time_fee_cents = order.purchases.first.fee_cents
        expect(Order::ChargeService).not_to receive(:new)

        responses = nil
        expect do
          responses = described_class.new(order:, params:, confirmation_token: token).perform
        end.to change { FailAbandonedPurchaseWorker.jobs.size }.by(1)

        response = responses["unique-id-0"]
        expect(response[:success]).to eq(true)
        expect(response[:requires_payment_confirmation]).to eq(true)
        expect(response[:client_secret]).to be_present
        expect(response[:order][:stripe_connect_account_id]).to be_nil
        expect(Order.find_by_secure_external_id(response[:order][:id], scope: "confirm")).to eq(order)

        # Mapping is persisted before responding so webhooks can resolve the order.
        expect(order.charges.count).to eq(1)
        charge = order.charges.last
        expect(charge.stripe_payment_intent_id).to be_present
        expect(charge).to be_client_confirmed
        expect(charge.amount_cents).to eq(order.purchases.sum(&:total_transaction_cents))

        # Fee recomputation: resolving the Gumroad-managed merchant account adds the Stripe processor
        # fee that combined-charge purchases exclude at create time, so gumroad_amount_cents is correct.
        expect(order.purchases.first.reload.fee_cents).to be > create_time_fee_cents
        expect(charge.gumroad_amount_cents).to eq(order.purchases.sum(&:total_transaction_amount_for_gumroad_cents))

        purchase = order.purchases.first
        expect(purchase.processor_payment_intent.intent_id).to eq(charge.stripe_payment_intent_id)
        expect(purchase.card_country).to eq("US")

        # Unconfirmed: nothing charged, purchases stay in progress.
        expect(order.purchases.successful).to be_empty
        expect(order.purchases.all?(&:in_progress?)).to eq(true)
        expect(order.purchases.map(&:stripe_transaction_id).compact).to be_empty
        expect(Stripe::PaymentIntent.retrieve(charge.stripe_payment_intent_id).status).to eq("requires_payment_method")
      end
    end

    context "when the previewed card country fails purchasing power parity verification" do
      before { create(:merchant_account, user: seller) }

      it "blocks pre-charge without creating an intent" do
        order, params = build_order
        purchase = order.purchases.first
        purchase.is_purchasing_power_parity_discounted = true
        purchase.ip_country = "India"

        responses = described_class.new(order:, params:, confirmation_token: confirmation_token_id).perform

        response = responses["unique-id-0"]
        expect(response[:success]).to eq(false)
        expect(response[:error_code]).to eq(PurchaseErrorCode::PPP_CARD_COUNTRY_NOT_MATCHING)
        # The buyer must receive the actionable explanation, not a null message that the UI
        # renders as a generic "something went wrong" (#5784).
        expect(response[:error_message]).to include("purchasing power parity discount")
        expect(order.charges).to be_empty
        expect(purchase.reload).to be_failed
        expect(ProcessorPaymentIntent.where(purchase:)).to be_empty
      end
    end

    # The country that drives PPP verification must come from whichever preview block the chosen
    # method exposes: card carries it directly, inline wallets (Link) do not, so fall back to the
    # method's typed block only — billing_details is intentionally excluded because it is
    # buyer-supplied and spoofable. Without the typed-block fallback a discounted Link purchase
    # fails on a nil country even when the wallet's country matches the buyer's.
    describe "previewed country extraction" do
      let(:service) { described_class.new(order: build_order.first, params: {}, confirmation_token: "ctoken_test") }

      def preview_from(hash)
        Stripe::StripeObject.construct_from(hash)
      end

      it "reads the country from the card block for a card preview" do
        preview = preview_from(type: "card", card: { country: "US" })
        expect(service.send(:previewed_country, preview)).to eq("US")
      end

      it "reads the country from the method-typed block for an inline wallet (Link) preview" do
        preview = preview_from(type: "link", link: { country: "DE" }, card: nil)
        expect(service.send(:previewed_country, preview)).to eq("DE")
      end

      it "does NOT trust buyer-supplied billing details (returns nil when only billing country is present)" do
        preview = preview_from(type: "link", link: {}, billing_details: { address: { country: "FR" } })
        expect(service.send(:previewed_country, preview)).to be_nil
      end

      it "returns nil when no Stripe-owned funding country is available" do
        preview = preview_from(type: "link", link: {})
        expect(service.send(:previewed_country, preview)).to be_nil
      end

      # U13 region-locked bucket: Stripe exposes no country on cashapp/us_bank_account previews, but
      # only a US Cash App account / US bank account can fund them — the lock IS the funding country.
      it "verifies a Cash App Pay preview as US via the region lock" do
        preview = preview_from(type: "cashapp", cashapp: {}, card: nil)
        expect(service.send(:previewed_country, preview)).to eq("US")
      end

      it "verifies an ACH (us_bank_account) preview as US via the region lock" do
        preview = preview_from(type: "us_bank_account", us_bank_account: { last4: "6789" }, card: nil)
        expect(service.send(:previewed_country, preview)).to eq("US")
      end

      it "prefers an explicit method-block country over the region lock if Stripe ever exposes one" do
        preview = preview_from(type: "us_bank_account", us_bank_account: { country: "US" }, card: nil)
        expect(service.send(:previewed_country, preview)).to eq("US")
      end
    end

    # U13: the deferred intent's method set must equal the Payment Element's on a PPP checkout, so
    # prepare recomputes the same ppp_discounted input from server-owned data (product PPP config +
    # the buyer's GeoIP-derived ip_country factor).
    context "with a PPP-eligible checkout (U13 method matrix)" do
      before do
        create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_test")
        product.update!(purchasing_power_parity_disabled: false)
        seller.update!(purchasing_power_parity_enabled: true)
        PurchasingPowerParityService.new.set_factor("US", 0.5)
      end

      after { PurchasingPowerParityService.new.set_factor("US", 1) }

      def create_args_for(order, params)
        preview = Stripe::StripeObject.construct_from(card: { country: "US" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_ppp").perform
        create_args
      end

      it "keeps card and the US-locked methods for a US PPP buyer, matching the Payment Element" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }

        expect(create_args_for(order, params)[:payment_method_types]).to eq(%w[card cashapp us_bank_account])
      end

      it "gates Link out of the intent on a PPP checkout" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }

        expect(create_args_for(order, params)[:payment_method_types]).to eq(%w[card cashapp us_bank_account])
      end

      it "does not gate the intent when the seller disabled PPP payment verification" do
        seller.update!(purchasing_power_parity_payment_verification_disabled: true)
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }

        expect(create_args_for(order, params)[:payment_method_types]).to eq(%w[card link cashapp us_bank_account])
      end
    end

    context "when no confirmation token is supplied" do
      before { create(:merchant_account, user: seller) }

      it "fails the purchases with the generic processing_error, not stripe_unavailable" do
        order, params = build_order

        responses = described_class.new(order:, params:, confirmation_token: nil).perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.charges).to be_empty
        purchase = order.purchases.first.reload
        expect(purchase).to be_failed
        expect(purchase.error_code).to eq(PurchaseErrorCode::PROCESSING_ERROR)
      end
    end

    context "when Stripe rejects the ConfirmationToken retrieve as an invalid request" do
      before { create(:merchant_account, user: seller) }

      it "fails the purchases with processor_invalid_request and keeps Stripe's error code" do
        order, params = build_order
        stripe_error = Stripe::InvalidRequestError.new("No such confirmation token", nil, code: "resource_missing")
        allow(Stripe::ConfirmationToken).to receive(:retrieve).and_raise(stripe_error)

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_test").perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        purchase = order.purchases.first.reload
        expect(purchase).to be_failed
        expect(purchase.error_code).to eq(PurchaseErrorCode::PROCESSOR_INVALID_REQUEST)
        expect(purchase.stripe_error_code).to eq("resource_missing")
      end
    end

    context "when Stripe is unreachable during the ConfirmationToken retrieve" do
      before { create(:merchant_account, user: seller) }

      it "fails the purchases with stripe_unavailable" do
        order, params = build_order
        allow(Stripe::ConfirmationToken).to receive(:retrieve).and_raise(Stripe::APIConnectionError.new("Connection reset"))

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_test").perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        purchase = order.purchases.first.reload
        expect(purchase).to be_failed
        expect(purchase.error_code).to eq(PurchaseErrorCode::STRIPE_UNAVAILABLE)
      end
    end

    context "when Stripe is unreachable during the intent create" do
      before { create(:merchant_account, user: seller) }

      it "fails the purchases with stripe_unavailable" do
        order, params = build_order
        preview = Stripe::StripeObject.construct_from(card: { country: "US" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))
        stripe_error = Stripe::APIConnectionError.new("Connection reset")
        allow(StripeDeferredPaymentIntent).to receive(:create)
          .and_raise(ChargeProcessorUnavailableError.new(original_error: stripe_error))

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_test").perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        purchase = order.purchases.first.reload
        expect(purchase).to be_failed
        expect(purchase.error_code).to eq(PurchaseErrorCode::STRIPE_UNAVAILABLE)
      end
    end

    context "when Stripe synchronously rejects the intent create as an invalid request" do
      before { create(:merchant_account, user: seller) }

      it "fails the purchases with processor_invalid_request and keeps Stripe's error code, not stripe_unavailable" do
        order, params = build_order
        preview = Stripe::StripeObject.construct_from(card: { country: "US" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))
        stripe_error = Stripe::InvalidRequestError.new("The payment method type \"cashapp\" is invalid.", nil, code: "payment_intent_invalid_parameter")
        allow(StripeDeferredPaymentIntent).to receive(:create)
          .and_raise(ChargeProcessorInvalidRequestError.new(original_error: stripe_error))

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_test").perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        purchase = order.purchases.first.reload
        expect(purchase).to be_failed
        expect(purchase.error_code).to eq(PurchaseErrorCode::PROCESSOR_INVALID_REQUEST)
        expect(purchase.stripe_error_code).to eq("payment_intent_invalid_parameter")
      end
    end

    # The browser attaches a buyer-currency quote token exactly when the checkout displayed
    # local-currency totals. Client-confirm charges canonical USD with no quote machinery, so a
    # token arriving here means the buyer confirmed an amount this lane cannot charge — it must
    # fail closed (like Charge::CreateService does) instead of silently charging USD.
    context "when the params carry a buyer-currency quote token" do
      before { create(:merchant_account, user: seller) }

      it "fails closed with the quote-invalid error code instead of preparing a canonical-USD intent" do
        order, params = build_order
        params[:buyer_currency_quote] = "some-signed-quote-token"

        expect(Stripe::ConfirmationToken).not_to receive(:retrieve)
        expect(StripeDeferredPaymentIntent).not_to receive(:create)

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_test").perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.charges).to be_empty
        purchase = order.purchases.first.reload
        expect(purchase).to be_failed
        expect(purchase.error_code).to eq(PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID)
      end
    end

    context "with a multi-seller cart" do
      let(:other_seller) { create(:user) }
      let(:other_product) { create(:product, user: other_seller, price_cents: 5_00) }

      before do
        create(:merchant_account, user: seller)
        create(:merchant_account, user: other_seller)
      end

      it "blocks pre-charge so one seller's charge can't be funded by another seller's line items" do
        params = {
          line_items: [
            line_item,
            { uid: "unique-id-1", permalink: other_product.unique_permalink, perceived_price_cents: other_product.price_cents, quantity: 1 },
          ]
        }.merge(common_params)
        order, = Order::CreateService.new(params:).perform

        expect(Stripe::ConfirmationToken).not_to receive(:retrieve)
        expect(StripeDeferredPaymentIntent).not_to receive(:create)

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_test").perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(responses["unique-id-1"][:success]).to eq(false)
        expect(order.charges).to be_empty
        expect(order.purchases.map(&:reload)).to all(be_failed)
      end
    end

    # #prepare is directly callable and only re-checks multi-seller; the charge path must re-check the
    # rest of the client-confirm cart shape server-side so a cart the presenter never mounts can't
    # slip through and hand Stripe a nil payment_method_types.
    context "with a cart the charge path deems client-confirm ineligible" do
      let(:seller) { create(:user, check_merchant_account_is_linked: true) }

      before do
        create(:merchant_account_stripe_connect, user: seller).update_column(:charge_processor_merchant_id, nil)
      end

      it "blocks pre-charge with a logged reason instead of building an intent with no method list" do
        order, params = build_order

        expect(Stripe::ConfirmationToken).not_to receive(:retrieve)
        expect(StripeDeferredPaymentIntent).not_to receive(:create)

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_test").perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.charges).to be_empty
        expect(order.purchases.first.reload).to be_failed
      end
    end

    context "with a direct-charge (Stripe Connect) seller" do
      let(:seller) { create(:user, check_merchant_account_is_linked: true) }
      let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }

      it "retrieves the ConfirmationToken and creates the intent on the connected account" do
        order, params = build_order

        preview = Stripe::StripeObject.construct_from(card: { country: "US" })
        expect(Stripe::ConfirmationToken).to receive(:retrieve)
          .with("ctoken_test", { stripe_account: connect_account.charge_processor_merchant_id })
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_test").perform

        expect(create_args[:merchant_account]).to eq(connect_account)
        response = responses["unique-id-0"]
        expect(response[:success]).to eq(true)
        expect(response[:requires_payment_confirmation]).to eq(true)
        expect(response[:order][:stripe_connect_account_id]).to eq(connect_account.charge_processor_merchant_id)
      end

      it "fails every purchase when the resolved merchant account rejects the cart instead of charging anyway" do
        order, params = build_order
        affiliate = create(:direct_affiliate, seller:)
        order.purchases.each { _1.update!(affiliate:) }
        connect_account.update!(country: "BR")

        preview = Stripe::StripeObject.construct_from(card: { country: "US" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))
        expect(StripeDeferredPaymentIntent).not_to receive(:create)

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_test").perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.charges).to be_empty
        expect(order.purchases.first.reload).to be_failed
      end
    end

    context "when the buyer's email is blocked by the seller" do
      before do
        create(:merchant_account, user: seller)
        BlockedCustomerObject.block_email!(email: common_params[:email], seller_id: seller.id)
      end

      it "blocks pre-charge without contacting Stripe or creating an intent" do
        order, params = build_order

        expect(Stripe::ConfirmationToken).not_to receive(:retrieve)
        expect(StripeDeferredPaymentIntent).not_to receive(:create)

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_test").perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(responses["unique-id-0"][:error_code]).to eq(PurchaseErrorCode::BLOCKED_CUSTOMER_EMAIL_ADDRESS)
        expect(order.charges).to be_empty
        expect(order.purchases.first.reload).to be_failed
      end
    end

    # The deferred intent's payment_method_types/currency MUST equal the Payment Element's, or Stripe
    # rejects the ConfirmationToken. Both sides read Checkout::PaymentMethodResolver so they can't drift.
    context "the deferred intent method/currency contract" do
      before { create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_test") }

      it "creates the intent with card and Link for a buyer whose country cannot be resolved (US-locked methods dropped)" do
        order, params = build_order

        preview = Stripe::StripeObject.construct_from(card: { country: "US" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_test").perform

        expect(create_args[:payment_method_types]).to eq(%w[card link])
        expect(create_args[:currency]).to eq(Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY)
      end

      # The launched set must equal the Payment Element's for the buyer's country, so Cash App Pay and
      # ACH Direct Debit ride the deferred intent only when the server-owned ip_country is the US.
      it "launches Cash App Pay and ACH Direct Debit for a US buyer, matching the Payment Element's method set" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }

        preview = Stripe::StripeObject.construct_from(card: { country: "US" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_us").perform

        expect(create_args[:payment_method_types]).to eq(%w[card link cashapp us_bank_account])
      end

      # The presenter derives the Element's Link config from the same resolver output, so the
      # Payment Element and deferred intent both carry "link" with no per-seller flag. Without a
      # resolvable ip_country the US-locked methods stay dropped — Link is not region-gated.
      it "always includes Link in the intent's payment_method_types" do
        order, params = build_order

        preview = Stripe::StripeObject.construct_from(card: { country: "US" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_test").perform

        expect(create_args[:payment_method_types]).to eq(%w[card link])
      end

      # A key built only from the (database-id-derived) external_id collides in Stripe test mode,
      # where idempotency keys persist for 24h across CI runs that reset the database and reuse ids;
      # scoping it to the fresh-per-attempt ConfirmationToken keeps it unique without losing idempotency.
      it "scopes the idempotency key to the confirmation token so a reused charge id cannot replay a stale intent" do
        order, params = build_order

        preview = Stripe::StripeObject.construct_from(card: { country: "US" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_unique_test").perform

        charge = order.charges.last
        expect(create_args[:idempotency_key]).to eq("deferred_intent_#{charge.external_id}_ctoken_unique_test")
      end
    end

    # Method-forced local payment methods (iDEAL/Bancontact) can only charge in one currency, so
    # when the buyer confirms with one, the deferred intent must be created in that currency with
    # the presentment snapshot persisted at prepare time (Local-Methods Join, issue #5419).
    context "with a method-forced local payment method (iDEAL)" do
      let(:seller) { create(:user, check_merchant_account_is_linked: true, disable_buyer_local_currency: false) }
      let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }

      before do
        # A capability snapshot must exist for the account to offer anything beyond card
        # (an uncached connect account resolves card-only while the refresh worker runs).
        connect_account.update!(stripe_capabilities_snapshot: {
                                  "capabilities" => { "link_payments" => "active" },
                                  "refreshed_at" => Time.current.iso8601,
                                })
        Feature.activate_user(:buyer_local_currency, seller)
        Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      end

      after do
        Feature.deactivate_user(:buyer_local_currency, seller)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      end

      def perform_with_ideal_preview(order, params, confirmation_token: "ctoken_ideal")
        preview = Stripe::StripeObject.construct_from(type: "ideal", ideal: {}, card: nil)
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_ideal", client_secret: "pi_ideal_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        responses = described_class.new(order:, params:, confirmation_token:).perform
        [create_args, responses]
      end

      context "with a USD-priced product (FX quote case)" do
        let(:quote) do
          StripeFxQuote::Quote.new(id: "fxq_prepare", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("1.25"))
        end

        before { allow(StripeFxQuote).to receive(:create).and_return(quote) }

        it "prepares the intent in EUR for the quote-converted amount with quote-backed presentment rows" do
          order, params = build_order
          create_args, responses = perform_with_ideal_preview(order, params)

          purchase = order.purchases.first.reload
          expected_total = ((BigDecimal(purchase.total_transaction_cents.to_s) / BigDecimal("1.25"))).round

          expect(create_args[:currency]).to eq(Currency::EUR)
          expect(create_args[:amount_cents]).to eq(expected_total)
          expect(create_args[:stripe_fx_quote_id]).to eq("fxq_prepare")
          expect(create_args[:payment_method_types]).to include("ideal")
          expect(responses["unique-id-0"][:success]).to eq(true)

          charge = order.charges.last
          expect(charge.charge_presentment).to have_attributes(presentment_currency: Currency::EUR,
                                                               presentment_total_cents: expected_total,
                                                               stripe_fx_quote_id: "fxq_prepare",
                                                               fx_rate: BigDecimal("1.25"))
          expect(purchase.purchase_presentment).to have_attributes(presentment_currency: Currency::EUR,
                                                                   presentment_total_cents: expected_total)
        end

        it "keys the intent on the FX quote id scoped to the confirmation token" do
          order, params = build_order
          create_args, = perform_with_ideal_preview(order, params, confirmation_token: "ctoken_quoted")

          charge = order.charges.last
          expect(create_args[:idempotency_key]).to eq("buyer-currency-intent-#{charge.external_id}-fxq_prepare_ctoken_quoted")
        end

        it "drops USD-only methods from the EUR intent for US buyers" do
          order, params = build_order
          order.purchases.each { _1.update!(ip_country: "United States") }

          create_args, = perform_with_ideal_preview(order, params)

          expect(create_args[:currency]).to eq(Currency::EUR)
          # The resolver no longer offers the forced-currency methods on a USD-priced cart
          # (they only mount on an element in their own currency), so the confirmed method
          # is appended individually by intent_payment_method_types; the USD-only methods
          # (cashapp/us_bank_account) are what this example guards against.
          expect(create_args[:payment_method_types]).to eq(%w[card link ideal])
          expect(create_args[:payment_method_types]).not_to include("cashapp", "us_bank_account")
        end
      end

      context "with a product priced in the forced currency (direct listed-amount case)" do
        let(:product) { create(:product, user: seller, price_currency_type: Currency::EUR, price_cents: 15_00) }
        let(:line_item) { { uid: "unique-id-0", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 } }

        it "prepares the intent for the listed EUR amount with no FX quote and null quote columns" do
          expect(StripeFxQuote).not_to receive(:create)

          order, params = build_order
          create_args, responses = perform_with_ideal_preview(order, params)

          purchase = order.purchases.first.reload
          expect(purchase.displayed_price_cents).to eq(15_00)

          expect(create_args[:currency]).to eq(Currency::EUR)
          expect(create_args[:amount_cents]).to eq(15_00)
          expect(create_args[:stripe_fx_quote_id]).to be_nil
          expect(create_args[:payment_method_types]).to include("ideal")
          expect(responses["unique-id-0"][:success]).to eq(true)

          charge = order.charges.last
          expect(charge.charge_presentment).to have_attributes(presentment_currency: Currency::EUR,
                                                               presentment_total_cents: 15_00,
                                                               stripe_fx_quote_id: nil,
                                                               stripe_fx_quote_expires_at: nil,
                                                               fx_rate: nil)
          expect(purchase.purchase_presentment).to have_attributes(presentment_currency: Currency::EUR,
                                                                   presentment_price_cents: 15_00,
                                                                   presentment_total_cents: 15_00)
        end

        it "keys the intent on the charge external id and currency (no quote), scoped to the confirmation token" do
          order, params = build_order
          create_args, = perform_with_ideal_preview(order, params, confirmation_token: "ctoken_direct")

          charge = order.charges.last
          expect(create_args[:idempotency_key]).to eq("buyer-currency-intent-#{charge.external_id}-#{Currency::EUR}_ctoken_direct")
        end

        # Scenario-4 regression (round-2 QA): the Payment Element mounts in EUR for this cart
        # shape, so a card ConfirmationToken minted on it is an EUR token — it can never confirm
        # a USD intent. Every method on the forced-currency element must charge through the
        # forced-currency intent, not just iDEAL/Bancontact.
        def perform_with_card_preview(order, params, confirmation_token: "ctoken_card_eur")
          preview = Stripe::StripeObject.construct_from(type: "card", card: { country: "NL" })
          allow(Stripe::ConfirmationToken).to receive(:retrieve)
            .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

          charge_intent = instance_double(StripeChargeIntent, id: "pi_card_eur", client_secret: "pi_card_eur_secret")
          create_args = nil
          allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
            create_args = kwargs
            charge_intent
          end

          responses = described_class.new(order:, params:, confirmation_token:).perform
          [create_args, responses]
        end

        it "prepares an EUR intent with presentment rows when the buyer pays by card on the forced-currency element" do
          expect(StripeFxQuote).not_to receive(:create)

          order, params = build_order
          create_args, responses = perform_with_card_preview(order, params)

          expect(create_args[:currency]).to eq(Currency::EUR)
          expect(create_args[:amount_cents]).to eq(15_00)
          expect(create_args[:stripe_fx_quote_id]).to be_nil
          expect(create_args[:payment_method_types]).to include("card")
          expect(create_args[:payment_method_types]).not_to include("cashapp", "us_bank_account")
          expect(responses["unique-id-0"][:success]).to eq(true)

          charge = order.charges.last
          expect(charge.charge_presentment).to have_attributes(presentment_currency: Currency::EUR,
                                                               presentment_total_cents: 15_00,
                                                               stripe_fx_quote_id: nil)
          expect(order.purchases.first.reload.purchase_presentment)
            .to have_attributes(presentment_currency: Currency::EUR, presentment_total_cents: 15_00)
        end

        it "fails closed instead of creating a USD intent when the card-path presentment build fails" do
          allow(ErrorNotifier).to receive(:notify)
          allow(Charge::PresentmentOrchestrator).to receive(:persist!).and_raise("presentment persist failed")

          order, params = build_order
          create_args, responses = perform_with_card_preview(order, params)

          expect(create_args).to be_nil
          expect(responses["unique-id-0"][:success]).to eq(false)
          order.purchases.each { expect(_1.reload.failed?).to eq(true) }
        end

        it "keeps the canonical USD intent for a card purchase of this EUR product when the flags are off" do
          Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)

          order, params = build_order
          create_args, responses = perform_with_card_preview(order, params, confirmation_token: "ctoken_card_flag_off")

          expect(create_args[:currency]).to eq(Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY)
          expect(create_args[:stripe_fx_quote_id]).to be_nil
          expect(responses["unique-id-0"][:success]).to eq(true)
          expect(order.charges.last.charge_presentment).to be_nil
        end
      end

      it "keeps today's canonical USD behavior byte-for-byte when the flag is off" do
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        expect(StripeFxQuote).not_to receive(:create)

        order, params = build_order
        create_args, responses = perform_with_ideal_preview(order, params, confirmation_token: "ctoken_flag_off")

        charge = order.charges.last
        expect(create_args[:currency]).to eq(Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY)
        expect(create_args[:amount_cents]).to eq(order.purchases.sum(&:total_transaction_cents))
        expect(create_args[:idempotency_key]).to eq("deferred_intent_#{charge.external_id}_ctoken_flag_off")
        expect(create_args[:payment_method_types]).not_to include("ideal")
        expect(responses["unique-id-0"][:success]).to eq(true)
        expect(charge.charge_presentment).to be_nil
        expect(order.purchases.first.reload.purchase_presentment).to be_nil
      end

      it "keeps today's canonical USD behavior for a non-method-forced payment method even with the flag on" do
        order, params = build_order

        preview = Stripe::StripeObject.construct_from(type: "card", card: { country: "US" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))
        charge_intent = instance_double(StripeChargeIntent, id: "pi_card", client_secret: "pi_card_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end
        expect(StripeFxQuote).not_to receive(:create)

        described_class.new(order:, params:, confirmation_token: "ctoken_card").perform

        charge = order.charges.last
        expect(create_args[:currency]).to eq(Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY)
        expect(create_args[:idempotency_key]).to eq("deferred_intent_#{charge.external_id}_ctoken_card")
        expect(charge.charge_presentment).to be_nil
      end

      # Once the buyer selected a forced-currency method, a missing presentment is not equivalent to
      # today's card-path USD fallback: Stripe cannot confirm iDEAL/Bancontact against a USD intent.
      it "fails closed without creating a USD intent when the presentment build fails" do
        allow(ErrorNotifier).to receive(:notify)
        allow(StripeFxQuote).to receive(:create).and_raise("fx quote unavailable")

        order, params = build_order
        create_args, responses = perform_with_ideal_preview(order, params)

        expect(create_args).to be_nil
        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.purchases.first.reload).to be_failed
        expect(order.charges.last.charge_presentment).to be_nil
      end

      # The presentment rows are persisted before the PaymentIntent is created. If that create
      # then fails, the purchases are failed immediately — so the payment_failed webhook and the
      # abandonment worker never run for this charge, and prepare itself must clean up the rows
      # it just persisted or they'd be orphaned.
      it "destroys the persisted presentment rows when the intent create fails after the presentment succeeded" do
        allow(StripeFxQuote).to receive(:create)
          .and_return(StripeFxQuote::Quote.new(id: "fxq_orphan", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("1.25")))

        preview = Stripe::StripeObject.construct_from(type: "ideal", ideal: {}, card: nil)
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))
        allow(StripeDeferredPaymentIntent).to receive(:create)
          .and_raise(ChargeProcessorUnavailableError.new("stripe down"))

        order, params = build_order
        responses = described_class.new(order:, params:, confirmation_token: "ctoken_orphan").perform

        purchase = order.purchases.first.reload
        expect(purchase.failed?).to eq(true)
        expect(responses["unique-id-0"][:success]).to eq(false)

        charge = order.charges.last
        expect(charge.charge_presentment).to be_nil
        expect(purchase.purchase_presentment).to be_nil
      end

      it "destroys the persisted presentment rows when an unexpected error escapes after the presentment succeeded" do
        allow(StripeFxQuote).to receive(:create)
          .and_return(StripeFxQuote::Quote.new(id: "fxq_unexpected", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("1.25")))

        preview = Stripe::StripeObject.construct_from(type: "ideal", ideal: {}, card: nil)
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))
        allow(StripeDeferredPaymentIntent).to receive(:create)
          .and_raise(RuntimeError, "merchant account missing id")

        order, params = build_order
        responses = described_class.new(order:, params:, confirmation_token: "ctoken_unexpected").perform

        purchase = order.purchases.first.reload
        expect(purchase).to be_failed
        expect(responses["unique-id-0"][:success]).to eq(false)

        charge = order.charges.last
        expect(charge.charge_presentment).to be_nil
        expect(purchase.purchase_presentment).to be_nil
      end

      # The rescue-path cleanup is best-effort: if the original error was database trouble, the
      # cleanup's own DB delete can raise too. That must not turn the buyer-facing error responses
      # into an unhandled exception (a 500) — the purchases are already failed at that point.
      it "still returns the error responses when the rescue-path cleanup itself raises" do
        allow(StripeFxQuote).to receive(:create)
          .and_return(StripeFxQuote::Quote.new(id: "fxq_cleanup_boom", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("1.25")))

        preview = Stripe::StripeObject.construct_from(type: "ideal", ideal: {}, card: nil)
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))
        allow(StripeDeferredPaymentIntent).to receive(:create)
          .and_raise(RuntimeError, "merchant account missing id")
        allow_any_instance_of(Charge).to receive(:destroy_presentment_records!)
          .and_raise(ActiveRecord::StatementInvalid, "database went away")
        expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::StatementInvalid), order_id: anything)

        order, params = build_order
        responses = nil
        expect do
          responses = described_class.new(order:, params:, confirmation_token: "ctoken_cleanup_boom").perform
        end.not_to raise_error

        purchase = order.purchases.first.reload
        expect(purchase).to be_failed
        expect(responses["unique-id-0"][:success]).to eq(false)
      end
    end

    context "when a purchase matches no line item in params" do
      # A bundle child (or any purchase whose permalink/variant is absent from params) must not be
      # keyed under nil, which silently drops its response and collides across purchases.
      it "keys the response by the computed cart-item uid instead of nil" do
        free_product = create(:product, user: seller, price_cents: 0)
        free_line_item = { uid: "unique-id-0", permalink: free_product.unique_permalink, perceived_price_cents: 0, quantity: 1 }
        params = { line_items: [free_line_item] }.merge(common_params)
        order, = Order::CreateService.new(params:).perform
        purchase = order.purchases.first

        # Params whose line_items don't reference this purchase's permalink force the fallback path.
        mismatched_params = params.merge(line_items: [free_line_item.merge(permalink: "nonexistent")])
        responses = described_class.new(order:, params: mismatched_params, confirmation_token: nil).perform

        expect(responses).not_to have_key(nil)
        expect(responses).to have_key("#{purchase.link.unique_permalink} #{purchase.variant_attributes.first&.external_id}")
      end
    end

    context "with a mixed free-and-paid single-seller cart" do
      before { create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_test") }

      # The free item must ride on the same charge as the paid one, so finalize's send_charge_receipts
      # covers it (matching Order::ChargeService). Otherwise mixed client-confirm carts skip receipts
      # for their free items.
      it "adds the free purchase to the charge alongside the paid one" do
        free_product = create(:product, user: seller, price_cents: 0)
        params = {
          line_items: [
            line_item,
            { uid: "unique-id-1", permalink: free_product.unique_permalink, perceived_price_cents: 0, quantity: 1 },
          ],
        }.merge(common_params)
        order, = Order::CreateService.new(params:).perform
        paid_purchase = order.purchases.find { _1.link_id == product.id }
        free_purchase = order.purchases.find { _1.link_id == free_product.id }

        preview = Stripe::StripeObject.construct_from(card: { country: "US" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))
        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        allow(StripeDeferredPaymentIntent).to receive(:create).and_return(charge_intent)

        described_class.new(order:, params:, confirmation_token: "ctoken_test").perform

        charge = order.charges.last
        expect(paid_purchase.reload.charge).to eq(charge)
        expect(free_purchase.reload.charge).to eq(charge)
        expect(free_purchase).to be_successful
        expect(charge.successful_purchases).to include(free_purchase)
        # The charge amount stays paid-only; the free item contributes nothing.
        expect(charge.amount_cents).to eq(paid_purchase.total_transaction_cents)
      end
    end
  end
end
