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

      it "verifies a UPI preview as IN via the region lock" do
        preview = preview_from(type: "upi", upi: {}, card: nil)
        expect(service.send(:previewed_country, preview)).to eq("IN")
      end

      # Klarna's US-only rule is a launch decision, not a Stripe funding-country lock: its preview
      # exposes no verifiable funding country, so PPP verification must NOT treat a Klarna payment
      # as US-funded — a nil country here means a PPP-discounted Klarna purchase fails closed.
      it "returns nil for a Klarna preview — the launch lock is not a funding country" do
        preview = preview_from(type: "klarna", klarna: {}, card: nil)
        expect(service.send(:previewed_country, preview)).to be_nil
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

        expect(create_args_for(order, params)[:payment_method_types]).to eq(%w[card cashapp])
      end

      it "gates Link out of the intent on a PPP checkout" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }

        expect(create_args_for(order, params)[:payment_method_types]).to eq(%w[card cashapp])
      end

      it "does not gate the intent when the seller disabled PPP payment verification" do
        seller.update!(purchasing_power_parity_payment_verification_disabled: true)
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }

        expect(create_args_for(order, params)[:payment_method_types]).to eq(%w[card link cashapp])
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

    context "when the client-confirm seller-proceeds guard rejects the PaymentIntent" do
      before { create(:merchant_account, user: seller) }

      it "returns the guard's buyer-facing error instead of the generic prepare failure" do
        order, params = build_order
        preview = Stripe::StripeObject.construct_from(card: { country: "US" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))
        allow(StripeDeferredPaymentIntent).to receive(:create).and_raise(
          ChargeProcessorCardError.new(PurchaseErrorCode::NET_NEGATIVE_SELLER_REVENUE, StripeIntentChargeRouting::SELLER_PROCEEDS_ERROR_MESSAGE)
        )

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_small_total").perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(responses["unique-id-0"][:error_message]).to eq(StripeIntentChargeRouting::SELLER_PROCEEDS_ERROR_MESSAGE)
        purchase = order.purchases.first.reload
        expect(purchase).to be_failed
        expect(purchase.stripe_error_code).to eq(PurchaseErrorCode::NET_NEGATIVE_SELLER_REVENUE)
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

    # An installment-plan purchase charges only its first installment now and the rest off-session
    # later, so it must resolve as recurring — the one-time set (Klarna included, for a flagged
    # seller) can never fund the later installments. The presenter already keeps installment carts
    # off the client-confirm lane (its resolver counts installments as recurring too), so this pins
    # the server-side re-check against a crafted #prepare request.
    context "with an installment-plan purchase" do
      before { create(:merchant_account, user: seller) }

      it "resolves as recurring and fails closed instead of minting a one-time deferred intent" do
        Feature.activate_user(:checkout_local_method_klarna, seller)
        installment_plan = create(:product_installment_plan, link: product)
        # Installment purchases charge the first installment now, so the perceived price the
        # buyer confirms is that first installment, not the full product price.
        first_installment_cents = installment_plan.calculate_installment_payment_price_cents(product.price_cents)
        order, params = build_order(line_item_overrides: { pay_in_installments: true, perceived_price_cents: first_installment_cents })
        expect(order.purchases.first.is_installment_payment).to eq(true)

        expect(Stripe::ConfirmationToken).not_to receive(:retrieve)
        expect(StripeDeferredPaymentIntent).not_to receive(:create)

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_installment").perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.charges).to be_empty
        expect(order.purchases.first.reload).to be_failed
      ensure
        Feature.deactivate_user(:checkout_local_method_klarna, seller)
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

        expect(create_args[:payment_method_types]).to eq(%w[card link cashapp])
      end

      # The presenter reads the checkout page's own remote_ip, this service reads the ip_country
      # stamped at order creation, so a buyer whose apparent location moves mid-checkout gets a US
      # Element and a non-US intent — and Stripe then rejects the ConfirmationToken for every method,
      # card included. See Checkout::PaymentMethodListToken.
      it "builds the intent from the page's issued method list when the persisted country would drop the US-locked methods" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "Greece") }
        params[:payment_method_list_token] = Checkout::PaymentMethodListToken.issue(
          payment_method_types: %w[card link cashapp], sellers: [seller]
        )

        preview = Stripe::StripeObject.construct_from(card: { country: "US" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_issued_list").perform

        expect(create_args[:payment_method_types]).to eq(%w[card link cashapp])
      end

      # The token settles which methods the Element offered, never whether a method may still be
      # offered at all: it was signed before a flag could roll back or an account could lose a
      # capability. So a replayed list cannot enable a method past its rollout gate — the same
      # allowlist a client-supplied ConfirmationToken type passes (gumroad-private#1143).
      it "drops a method from the issued list that this seller may no longer offer" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }
        params[:payment_method_list_token] = Checkout::PaymentMethodListToken.issue(
          payment_method_types: %w[card link cashapp klarna], sellers: [seller]
        )

        preview = Stripe::StripeObject.construct_from(card: { country: "US" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_issued_gate").perform

        # Klarna's launch flag is off for this seller, so it never reaches the intent even though
        # the signed list names it.
        expect(create_args[:payment_method_types]).to eq(%w[card link cashapp])
      end

      # A crafted or replayed list must not widen past a rollout gate, and a checkout page that
      # predates the token must behave exactly as today — both land on re-resolving.
      it "ignores an unverifiable list and re-resolves" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "Greece") }

        preview = Stripe::StripeObject.construct_from(card: { country: "US" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        params[:payment_method_list_token] = "not-a-real-token"
        described_class.new(order:, params:, confirmation_token: "ctoken_forged_list").perform
        expect(create_args[:payment_method_types]).to eq(%w[card link])
      end

      # The final-amount strip runs over a verified issued list exactly as it does over a
      # re-resolved one: klarna on an out-of-window cart fails the intent CREATE, taking down the
      # whole cart including the buyer who picked card.
      it "strips klarna from a verified issued list when the final amount is outside Stripe's Klarna window" do
        Feature.activate_user(:checkout_local_method_klarna, seller)
        expensive_product = create(:product, user: seller, price_cents: 5_000_00)
        params = { line_items: [{ uid: "unique-id-0", permalink: expensive_product.unique_permalink, perceived_price_cents: expensive_product.price_cents, quantity: 1 }] }.merge(common_params)
        order, = Order::CreateService.new(params:).perform
        order.purchases.each { _1.update!(ip_country: "United States") }
        params[:payment_method_list_token] = Checkout::PaymentMethodListToken.issue(
          payment_method_types: %w[card link cashapp klarna], sellers: [seller]
        )

        preview = Stripe::StripeObject.construct_from(card: { country: "US" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_issued_window").perform

        expect(create_args[:payment_method_types]).to eq(%w[card link cashapp])
      ensure
        Feature.deactivate_user(:checkout_local_method_klarna, seller)
      end

      # Klarna joins the intent only when its launch flag is on AND the final charged total sits
      # inside Stripe's Klarna USD window — the same resolver both the presenter and this service
      # read, so the Element's list and the intent's list stay equal.
      it "adds Klarna to the deferred intent for a flagged seller and eligible US cart" do
        Feature.activate_user(:checkout_local_method_klarna, seller)
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

        described_class.new(order:, params:, confirmation_token: "ctoken_klarna").perform

        expect(create_args[:payment_method_types]).to eq(%w[card link cashapp klarna])
        expect(create_args[:currency]).to eq(Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY)
      ensure
        Feature.deactivate_user(:checkout_local_method_klarna, seller)
      end

      it "keeps Klarna off the deferred intent when the charged total is outside Stripe's Klarna window" do
        Feature.activate_user(:checkout_local_method_klarna, seller)
        expensive_product = create(:product, user: seller, price_cents: 5_000_00)
        params = { line_items: [{ uid: "unique-id-0", permalink: expensive_product.unique_permalink, perceived_price_cents: expensive_product.price_cents, quantity: 1 }] }.merge(common_params)
        order, = Order::CreateService.new(params:).perform
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

        described_class.new(order:, params:, confirmation_token: "ctoken_klarna_big").perform

        expect(create_args[:payment_method_types]).to eq(%w[card link cashapp])
      ensure
        Feature.deactivate_user(:checkout_local_method_klarna, seller)
      end

      it "keeps Klarna off the deferred intent without its launch flag — the 0% default" do
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

        described_class.new(order:, params:, confirmation_token: "ctoken_no_klarna").perform

        expect(create_args[:payment_method_types]).to eq(%w[card link cashapp])
      end

      # The launch flag is the rollout gate, and the previewed-method append must not be a
      # way around it: a klarna ConfirmationToken arriving while the seller's flag is off
      # (rolled back mid-checkout, or crafted for a seller the rollout never reached) must
      # NOT re-enter the intent's method list. The intent stays byte-for-byte the flag-off
      # list and the stale token fails closed at confirm — the same fail-closed shape as a
      # forced-currency token after its launch flag rolls back.
      it "does not append a klarna token to the USD intent when the seller's launch flag is off" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }

        preview = Stripe::StripeObject.construct_from(type: "klarna", klarna: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        # The Klarna flag is OFF for this seller: the resolver omits klarna and the append
        # must not put it back.
        described_class.new(order:, params:, confirmation_token: "ctoken_klarna_drift").perform

        expect(create_args[:payment_method_types]).to eq(%w[card link cashapp])
      end

      # With the flag ON, the append is the drift safety net it was built to be: a launched
      # seller's klarna token stays on the intent even if the re-run resolver's OTHER inputs
      # drift (any of them — here the drift is simulated at the resolver's public boundary by
      # having resolve return a set without klarna, rather than stubbing a private gate that
      # can't actually answer false for this platform-account seller).
      it "appends a launched seller's klarna token to the USD intent when the re-run resolver drops it" do
        Feature.activate_user(:checkout_local_method_klarna, seller)
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }

        preview = Stripe::StripeObject.construct_from(type: "klarna", klarna: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        # Simulate resolver-input drift: the resolver drops klarna at prepare even though the
        # Element offered it (and the buyer confirmed with it) when it mounted.
        allow_any_instance_of(Checkout::PaymentMethodResolver).to receive(:resolve).and_return(
          Checkout::PaymentMethodResolver::Resolution.new(
            client_confirm_eligible: true,
            payment_method_types: %w[card link cashapp],
            eligible_payment_method_types: %w[card link cashapp],
            fallback_reason: nil,
            stripe_connect_account_id: nil
          )
        )

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_klarna_drift_on").perform

        expect(create_args[:payment_method_types]).to eq(%w[card link cashapp klarna])
      ensure
        Feature.deactivate_user(:checkout_local_method_klarna, seller)
      end

      # The append re-checks the resolver's merchant-account gate, not just the launch flag:
      # a klarna entry on a non-US connected account's intent fails the ENTIRE intent create
      # (Stripe's cross-border rule — the gumroad-private#1026 failure mode), so capability or
      # account drift after the Element mounts must fail the stale token closed at confirm
      # instead of re-appending the method.
      it "does not append a klarna token when the seller's connected account is not US-based, even with the launch flag on" do
        connect_seller = create(:user, check_merchant_account_is_linked: true)
        create(:merchant_account_stripe_connect, user: connect_seller, country: "DE")
        Feature.activate_user(:checkout_local_method_klarna, connect_seller)
        connect_product = create(:product, user: connect_seller, price_cents: 10_00)
        params = { line_items: [{ uid: "unique-id-0", permalink: connect_product.unique_permalink, perceived_price_cents: connect_product.price_cents, quantity: 1 }] }.merge(common_params)
        order, = Order::CreateService.new(params:).perform
        order.purchases.each { _1.update!(ip_country: "United States") }

        preview = Stripe::StripeObject.construct_from(type: "klarna", klarna: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_klarna_de_acct").perform

        expect(create_args[:payment_method_types]).not_to include("klarna")
      ensure
        Feature.deactivate_user(:checkout_local_method_klarna, connect_seller)
      end

      # Alipay's append gate is the launch flag alone, mirroring its resolver gate. Flag off,
      # a stale or crafted alipay token must not re-enter the intent's method list — it fails
      # closed at confirm instead, exactly like a rolled-back klarna token.
      it "does not append an alipay token to the USD intent when the seller's launch flag is off" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }

        preview = Stripe::StripeObject.construct_from(type: "alipay", alipay: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_alipay_drift").perform

        expect(create_args[:payment_method_types]).to eq(%w[card link cashapp])
      end

      # Flag on, the append is the drift safety net: a launched seller's alipay token stays on
      # the intent even when the re-run resolver's inputs drift and it drops the method.
      it "appends a launched seller's alipay token to the USD intent when the re-run resolver drops it" do
        Feature.activate_user(:checkout_local_method_alipay, seller)
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }

        preview = Stripe::StripeObject.construct_from(type: "alipay", alipay: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        allow_any_instance_of(Checkout::PaymentMethodResolver).to receive(:resolve).and_return(
          Checkout::PaymentMethodResolver::Resolution.new(
            client_confirm_eligible: true,
            payment_method_types: %w[card link cashapp],
            eligible_payment_method_types: %w[card link cashapp],
            fallback_reason: nil,
            stripe_connect_account_id: nil
          )
        )

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_alipay_drift_on").perform

        expect(create_args[:payment_method_types]).to eq(%w[card link cashapp alipay])
      ensure
        Feature.deactivate_user(:checkout_local_method_alipay, seller)
      end

      # Stripe ties Alipay presentment currencies to the account's business country and `usd` is
      # United States only, so a non-US connected account must never carry an alipay entry on this
      # lane's USD intent — the incompatible entry fails the ENTIRE intent create, taking card
      # down with it (gumroad-private#1026). The resolver is stubbed to a card-only set here so
      # the assertion exercises the append clause's own account gate rather than the resolver's.
      it "does not append an alipay token on a non-US connected account even when its alipay_payments capability is active" do
        connect_seller = create(:user, check_merchant_account_is_linked: true)
        connect_account = create(:merchant_account_stripe_connect, user: connect_seller, country: "DE")
        connect_account.update!(stripe_capabilities_snapshot: {
                                  "capabilities" => { "alipay_payments" => "active" },
                                  "refreshed_at" => Time.current.iso8601,
                                })
        Feature.activate_user(:checkout_local_method_alipay, connect_seller)
        connect_product = create(:product, user: connect_seller, price_cents: 10_00)
        params = { line_items: [{ uid: "unique-id-0", permalink: connect_product.unique_permalink, perceived_price_cents: connect_product.price_cents, quantity: 1 }] }.merge(common_params)
        order, = Order::CreateService.new(params:).perform
        order.purchases.each { _1.update!(ip_country: "United States") }

        preview = Stripe::StripeObject.construct_from(type: "alipay", alipay: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        allow_any_instance_of(Checkout::PaymentMethodResolver).to receive(:resolve).and_return(
          Checkout::PaymentMethodResolver::Resolution.new(
            client_confirm_eligible: true,
            payment_method_types: %w[card],
            eligible_payment_method_types: %w[card],
            fallback_reason: nil,
            stripe_connect_account_id: connect_account.charge_processor_merchant_id
          )
        )

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_alipay_de_acct").perform

        expect(create_args[:payment_method_types]).not_to include("alipay")
      ensure
        Feature.deactivate_user(:checkout_local_method_alipay, connect_seller)
      end

      # The append re-checks the per-account capability intersection for Alipay too: a connected
      # account that never enabled alipay_payments must not have the method re-appended, because
      # that would make Stripe reject the ENTIRE intent create, taking card down with it
      # (gumroad-private#1026).
      it "does not append an alipay token when the connected account's alipay_payments capability is not active" do
        connect_seller = create(:user, check_merchant_account_is_linked: true)
        connect_account = create(:merchant_account_stripe_connect, user: connect_seller)
        connect_account.update!(stripe_capabilities_snapshot: {
                                  "capabilities" => { "card_payments" => "active" },
                                  "refreshed_at" => Time.current.iso8601,
                                })
        Feature.activate_user(:checkout_local_method_alipay, connect_seller)
        connect_product = create(:product, user: connect_seller, price_cents: 10_00)
        params = { line_items: [{ uid: "unique-id-0", permalink: connect_product.unique_permalink, perceived_price_cents: connect_product.price_cents, quantity: 1 }] }.merge(common_params)
        order, = Order::CreateService.new(params:).perform
        order.purchases.each { _1.update!(ip_country: "United States") }

        preview = Stripe::StripeObject.construct_from(type: "alipay", alipay: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_alipay_no_cap").perform

        expect(create_args[:payment_method_types]).not_to include("alipay")
      ensure
        Feature.deactivate_user(:checkout_local_method_alipay, connect_seller)
      end

      # The append also re-checks the per-account CAPABILITY intersection, not just the
      # resolver's policy sources: for a direct-charge seller whose capability snapshot
      # dropped a launched method (link_payments deactivated after the Element mounted),
      # re-appending the token's type would put an incompatible payment_method_types entry
      # on the intent and Stripe rejects the ENTIRE intent create — failing card checkout
      # for that seller too (the gumroad-private#1026 failure mode). The stale token must
      # fail closed at confirm instead.
      it "does not re-append a launched method the connected account's capability snapshot does not support" do
        connect_seller = create(:user, check_merchant_account_is_linked: true)
        connect_account = create(:merchant_account_stripe_connect, user: connect_seller, country: "US")
        # link_payments is deliberately absent: the snapshot says this account cannot take Link.
        connect_account.update!(stripe_capabilities_snapshot: {
                                  "capabilities" => { "cashapp_payments" => "active" },
                                  "refreshed_at" => Time.current.iso8601,
                                })
        connect_product = create(:product, user: connect_seller, price_cents: 10_00)
        params = { line_items: [{ uid: "unique-id-0", permalink: connect_product.unique_permalink, perceived_price_cents: connect_product.price_cents, quantity: 1 }] }.merge(common_params)
        order, = Order::CreateService.new(params:).perform
        order.purchases.each { _1.update!(ip_country: "United States") }

        preview = Stripe::StripeObject.construct_from(type: "link", link: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_link_no_capability").perform

        expect(create_args[:payment_method_types]).not_to include("link")
      end

      # And the positive half: when the snapshot DOES carry the capability, the append stays
      # the drift safety net — a supported method the re-run resolver dropped for any other
      # reason is kept on the intent so the buyer's confirmed token can still charge.
      it "re-appends a launched method the connected account's capability snapshot supports when the resolver drops it" do
        connect_seller = create(:user, check_merchant_account_is_linked: true)
        connect_account = create(:merchant_account_stripe_connect, user: connect_seller, country: "US")
        connect_account.update!(stripe_capabilities_snapshot: {
                                  "capabilities" => { "link_payments" => "active" },
                                  "refreshed_at" => Time.current.iso8601,
                                })
        connect_product = create(:product, user: connect_seller, price_cents: 10_00)
        params = { line_items: [{ uid: "unique-id-0", permalink: connect_product.unique_permalink, perceived_price_cents: connect_product.price_cents, quantity: 1 }] }.merge(common_params)
        order, = Order::CreateService.new(params:).perform
        order.purchases.each { _1.update!(ip_country: "United States") }

        preview = Stripe::StripeObject.construct_from(type: "link", link: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        # Simulate resolver drift: the re-run resolver returns a set without link even though
        # the Element offered it when it mounted.
        allow_any_instance_of(Checkout::PaymentMethodResolver).to receive(:resolve).and_return(
          Checkout::PaymentMethodResolver::Resolution.new(
            client_confirm_eligible: true,
            payment_method_types: %w[card],
            eligible_payment_method_types: %w[card],
            fallback_reason: nil,
            stripe_connect_account_id: connect_account.charge_processor_merchant_id
          )
        )

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_link_with_capability").perform

        expect(create_args[:payment_method_types]).to include("link")
      end

      # A connected account with NO capability snapshot fails the append closed: the resolver
      # resolved this same checkout to card-only (its nil-snapshot fallback), so the Element
      # never offered the method — there is no legitimate drift to protect, and appending
      # anyway would gamble the intent create on an unverified capability.
      it "does not re-append a non-card method for a connected account with no capability snapshot" do
        connect_seller = create(:user, check_merchant_account_is_linked: true)
        create(:merchant_account_stripe_connect, user: connect_seller, country: "US")
        connect_product = create(:product, user: connect_seller, price_cents: 10_00)
        params = { line_items: [{ uid: "unique-id-0", permalink: connect_product.unique_permalink, perceived_price_cents: connect_product.price_cents, quantity: 1 }] }.merge(common_params)
        order, = Order::CreateService.new(params:).perform
        order.purchases.each { _1.update!(ip_country: "United States") }

        preview = Stripe::StripeObject.construct_from(type: "link", link: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_link_no_snapshot").perform

        expect(create_args[:payment_method_types]).not_to include("link")
      end

      # The append is allowlisted to methods this seller could legitimately be offered — it
      # must never let a client-supplied token type re-enable a method past its policy gate.
      # ACH is the sharpest case: the capability is still active at Stripe (the withdrawal in
      # gumroad-private#1143 is policy-level), so without the allowlist the intent create
      # SUCCEEDS and the buyer actually pays by a method the seller never opted into.
      it "does not append a us_bank_account token to the USD intent for a seller who has not opted into ACH" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }

        preview = Stripe::StripeObject.construct_from(type: "us_bank_account", us_bank_account: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_ach_not_opted_in").perform

        expect(create_args[:payment_method_types]).to eq(%w[card link cashapp])
      end

      it "appends a us_bank_account token when the seller HAS opted into ACH — the drift safety net still covers the opt-in method" do
        seller.update!(ach_payments_enabled: true)
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }

        preview = Stripe::StripeObject.construct_from(type: "us_bank_account", us_bank_account: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_ach_opted_in").perform

        expect(create_args[:payment_method_types]).to include("us_bank_account")
      ensure
        seller.update!(ach_payments_enabled: false)
      end

      # Unlaunched BNPL types (afterpay_clearpay, affirm) are excluded from Klarna's first
      # launch; listing one would make Stripe reject the whole intent create
      # (gumroad-private#1026). The allowlist drops them and the stale token fails closed
      # at confirm.
      it "does not append an unlaunched BNPL token (afterpay_clearpay) to the USD intent" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }

        preview = Stripe::StripeObject.construct_from(type: "afterpay_clearpay", afterpay_clearpay: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_test", client_secret: "pi_test_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        described_class.new(order:, params:, confirmation_token: "ctoken_afterpay").perform

        expect(create_args[:payment_method_types]).to eq(%w[card link cashapp])
      end

      # Klarna is US-only in v1 but deliberately lives outside US_LOCKED_PAYMENT_METHOD_TYPES
      # (that constant also feeds the PPP funding-country fallback, and Klarna's funding country
      # is not verifiable pre-charge) — so the region-lock gate must cover it explicitly. Without
      # that, a non-US buyer's Klarna ConfirmationToken would slip past the gate and the
      # previewed-method append would put klarna on a USD intent the v1 gate never vetted;
      # Stripe would then reject the confirm instead of the order failing closed here.
      it "fails closed before creating an intent when a non-US buyer confirms with Klarna" do
        Feature.activate_user(:checkout_local_method_klarna, seller)
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "France") }

        preview = Stripe::StripeObject.construct_from(type: "klarna", klarna: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        expect(StripeDeferredPaymentIntent).not_to receive(:create)

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_klarna_fr").perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.purchases.first.reload).to be_failed
      ensure
        Feature.deactivate_user(:checkout_local_method_klarna, seller)
      end

      # Same gate, unknown GeoIP: an unresolvable buyer country fails closed for Klarna,
      # matching the resolver (which never offers Klarna without a US GeoIP answer).
      it "fails closed for a Klarna token when the buyer's country cannot be resolved" do
        Feature.activate_user(:checkout_local_method_klarna, seller)
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: nil) }

        preview = Stripe::StripeObject.construct_from(type: "klarna", klarna: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        expect(StripeDeferredPaymentIntent).not_to receive(:create)

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_klarna_unknown").perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.purchases.first.reload).to be_failed
      ensure
        Feature.deactivate_user(:checkout_local_method_klarna, seller)
      end

      it "reconstructs the full quantity total for a once-per-cart fixed discount" do
        offer_code = create(:offer_code, user: seller, products: [product], amount_cents: 1_00, once_per_cart: true)
        params = {
          line_items: [{ uid: "unique-id-0", permalink: product.unique_permalink, price_cents: 20_00,
                         perceived_price_cents: 19_00, quantity: 2,
                         discount_code: offer_code.code }]
        }.merge(common_params)
        order, order_responses = Order::CreateService.new(params:).perform
        expect(order_responses.values).to all(include(success: true))

        service = described_class.new(order:, params:, confirmation_token: "unused")

        expect(service.send(:klarna_window_price_cents, order.purchases.first)).to eq(20_00)
      end

      it "excludes the tip from the submitted Klarna window total" do
        seller.update!(tipping_enabled: true)
        offer_code = create(:offer_code, user: seller, products: [product], amount_cents: 1_00, once_per_cart: true)
        params = {
          line_items: [{ uid: "unique-id-0", permalink: product.unique_permalink, price_cents: 21_00,
                         perceived_price_cents: 20_00, tip_cents: 1_00, quantity: 2,
                         discount_code: offer_code.code }]
        }.merge(common_params)
        order, order_responses = Order::CreateService.new(params:).perform
        expect(order_responses.values).to all(include(success: true))

        service = described_class.new(order:, params:, confirmation_token: "unused")

        expect(service.send(:klarna_window_price_cents, order.purchases.first)).to eq(20_00)
      end

      it "uses the submitted total when a once-per-cart discount is clamped" do
        offer_code = create(:offer_code, user: seller, products: [product], amount_cents: 20_00, once_per_cart: true)
        params = {
          line_items: [{ uid: "unique-id-0", permalink: product.unique_permalink, price_cents: 10_00,
                         perceived_price_cents: 0, quantity: 1, discount_code: offer_code.code }]
        }.merge(common_params)
        order, order_responses = Order::CreateService.new(params:).perform
        expect(order_responses.values).to all(include(success: true))

        service = described_class.new(order:, params:, confirmation_token: "unused")

        expect(service.send(:klarna_window_price_cents, order.purchases.first)).to eq(10_00)
      end

      it "uses the saved price when an earlier duplicate line failed" do
        offer_code = create(:offer_code, user: seller, products: [product], amount_cents: 1_00, once_per_cart: true)
        params = {
          line_items: [{ uid: "successful", permalink: product.unique_permalink, price_cents: 20_00,
                         perceived_price_cents: 19_00, quantity: 2,
                         discount_code: offer_code.code }]
        }.merge(common_params)
        order, order_responses = Order::CreateService.new(params:).perform
        expect(order_responses.values).to all(include(success: true))
        params[:line_items].unshift(uid: "failed", permalink: product.unique_permalink, price_cents: 10_00)

        service = described_class.new(order:, params:, confirmation_token: "unused")

        expect(service.send(:klarna_window_price_cents, order.purchases.first)).to eq(20_00)
      end

      # PWYW + offer-code regression: the presenter's Klarna window input is the buyer's
      # CHOSEN pre-discount amount (cart_product.price), so prepare must reconstruct that
      # same basis. displayed_price_cents_before_offer_code would instead return the
      # product's FLOOR price for a cached offer code, and a buyer paying above floor could
      # then get Klarna from one side but not the other — an Element/intent method-set
      # mismatch that fails the whole cart at confirm.
      it "computes the Klarna window from the buyer's chosen PWYW amount, not the product floor, when an offer code is cached" do
        Feature.activate_user(:checkout_local_method_klarna, seller)
        # Floor $2 (the smallest floor a 50%-off code's post-discount-≥-$0.99 validation
        # allows), buyer chooses $4,500 — above Klarna's $4,000 window maximum — and pays
        # $2,250 after the code. Chosen pre-discount basis: $4,500 → OUTSIDE the window →
        # Klarna stays off the intent, matching the Element the presenter mounted from the
        # same $4,500. The floor basis ($2, inside the window) would wrongly add it.
        pwyw_product = create(:product, user: seller, price_cents: 2_00, customizable_price: true)
        offer_code = create(:percentage_offer_code, user: seller, products: [pwyw_product], amount_percentage: 50)
        params = {
          line_items: [{ uid: "unique-id-0", permalink: pwyw_product.unique_permalink, perceived_price_cents: 2_250_00, quantity: 1,
                         discount_code: offer_code.code }]
        }.merge(common_params)
        order, order_responses = Order::CreateService.new(params:).perform
        expect(order_responses.values).to all(include(success: true))
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

        described_class.new(order:, params:, confirmation_token: "ctoken_pwyw_klarna").perform

        expect(create_args[:payment_method_types]).not_to include("klarna")
        expect(create_args[:payment_method_types]).to include("card")
      ensure
        Feature.deactivate_user(:checkout_local_method_klarna, seller)
      end

      # Stripe validates Klarna's transaction limits against the intent's FINAL amount, while
      # the resolver (deliberately) gates on the pre-tax, pre-discount basis for Element/intent
      # method-set parity. When the two diverge across the window edge — here a 50%-off code
      # drops a $1.98 cart (inside the window on the pre-discount basis both sides resolve on)
      # to a $0.99 charge (below Klarna's $1 floor) — a Klarna confirmation must fail closed
      # before any intent exists: an intent listing klarna at that amount is rejected by Stripe
      # at create with no recoverable buyer action.
      it "fails closed before creating an intent when the final charged amount leaves Klarna's window" do
        Feature.activate_user(:checkout_local_method_klarna, seller)
        discounted_product = create(:product, user: seller, price_cents: 1_98)
        offer_code = create(:percentage_offer_code, user: seller, products: [discounted_product], amount_percentage: 50)
        params = {
          line_items: [{ uid: "unique-id-0", permalink: discounted_product.unique_permalink, perceived_price_cents: 99, quantity: 1,
                         discount_code: offer_code.code }]
        }.merge(common_params)
        order, order_responses = Order::CreateService.new(params:).perform
        expect(order_responses.values).to all(include(success: true))
        order.purchases.each { _1.update!(ip_country: "United States") }

        preview = Stripe::StripeObject.construct_from(type: "klarna", klarna: {})
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        expect(StripeDeferredPaymentIntent).not_to receive(:create)

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_klarna_final_drift").perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        # The rejection is deterministic — retrying Klarna on the same cart can never succeed —
        # so the buyer must get the actionable "choose a different payment method" message, not
        # the retry-oriented generic one.
        expect(responses["unique-id-0"][:error_message]).to eq(described_class::KLARNA_AMOUNT_INELIGIBLE_MESSAGE)
        expect(order.purchases.first.reload).to be_failed
      ensure
        Feature.deactivate_user(:checkout_local_method_klarna, seller)
      end

      # Same amount drift, but the buyer confirmed with CARD: their purchase must proceed —
      # klarna is silently dropped from the intent's method list (listing it above/below
      # Stripe's Klarna limit fails the intent CREATE itself, taking the card buyer down with
      # it) while the confirmed method rides untouched.
      it "drops Klarna from a card buyer's intent when the final charged amount leaves the window, instead of failing the create" do
        Feature.activate_user(:checkout_local_method_klarna, seller)
        discounted_product = create(:product, user: seller, price_cents: 1_98)
        offer_code = create(:percentage_offer_code, user: seller, products: [discounted_product], amount_percentage: 50)
        params = {
          line_items: [{ uid: "unique-id-0", permalink: discounted_product.unique_permalink, perceived_price_cents: 99, quantity: 1,
                         discount_code: offer_code.code }]
        }.merge(common_params)
        order, order_responses = Order::CreateService.new(params:).perform
        expect(order_responses.values).to all(include(success: true))
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

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_card_klarna_drift").perform

        expect(responses["unique-id-0"][:success]).to eq(true)
        expect(create_args[:payment_method_types]).not_to include("klarna")
        expect(create_args[:payment_method_types]).to include("card")
      ensure
        Feature.deactivate_user(:checkout_local_method_klarna, seller)
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
                                  "capabilities" => { "link_payments" => "active", "ideal_payments" => "active" },
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

        # A destination-charge seller (Gumroad-managed Stripe Custom account) with the
        # destination-charge ramp flag off. Charge::MethodForcedPresentment returns nil here,
        # and on THIS lane nil is not the card path's quiet canonical-USD fallback: the buyer
        # already confirmed on a forced-currency element, so #client_confirm_presentment_required?
        # turns the nil into a clean synchronous failure with no PaymentIntent and no Stripe
        # quote call. Pinned because the alternative — creating a USD intent — would produce an
        # intent the EUR ConfirmationToken can never confirm, leaving the purchase in_progress
        # until the abandonment worker.
        context "with a destination-charge seller and the destination ramp flag off" do
          let(:seller) { create(:user, disable_buyer_local_currency: false) }
          let!(:connect_account) { create(:merchant_account, user: seller, currency: Currency::USD) }
          # The platform account has to exist, or the quote would be withheld for the unrelated
          # reason that there is no account to mint it on — the example would pass without
          # exercising the ramp flag at all.
          let!(:platform_merchant_account) do
            MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)&.tap do |account|
              account.update!(currency: Currency::USD)
            end || create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_gumroad_platform", currency: Currency::USD)
          end

          it "fails closed without creating an intent or calling Stripe for a quote" do
            expect(StripeFxQuote).not_to receive(:create)

            order, params = build_order
            create_args, responses = perform_with_ideal_preview(order, params, confirmation_token: "ctoken_destination_off")

            expect(create_args).to be_nil
            expect(responses["unique-id-0"][:success]).to eq(false)
            expect(order.purchases.first.reload).to be_failed
            expect(order.charges.last&.charge_presentment).to be_nil
          end
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

        it "prepares one forced-currency intent for a multi-item cart uniformly priced in the forced currency" do
          expect(StripeFxQuote).not_to receive(:create)
          other_product = create(:product, user: seller, price_currency_type: Currency::EUR, price_cents: 7_00)
          params = {
            line_items: [
              line_item,
              { uid: "unique-id-1", permalink: other_product.unique_permalink, perceived_price_cents: other_product.price_cents, quantity: 1 },
            ],
          }.merge(common_params)
          order, = Order::CreateService.new(params:).perform

          create_args, responses = perform_with_ideal_preview(order, params, confirmation_token: "ctoken_multi_direct")

          expect(create_args[:currency]).to eq(Currency::EUR)
          expect(create_args[:amount_cents]).to eq(22_00)
          expect(create_args[:stripe_fx_quote_id]).to be_nil
          expect(responses["unique-id-0"][:success]).to eq(true)
          expect(responses["unique-id-1"][:success]).to eq(true)

          charge = order.charges.last
          expect(charge.charge_presentment).to have_attributes(presentment_currency: Currency::EUR,
                                                               presentment_total_cents: 22_00,
                                                               stripe_fx_quote_id: nil)
          expect(order.purchases.map { _1.reload.purchase_presentment.presentment_total_cents }).to contain_exactly(15_00, 7_00)
        end

        # The Payment Element mounts at the quantity-inclusive cart subtotal (the presenter
        # multiplies per-unit price by quantity), so prepare must create the intent for the same
        # number. If prepare summed per-unit prices instead, a quantity-2 cart would confirm an
        # EUR 15.00 intent against an Element that showed EUR 30.00 and Stripe would reject it.
        it "prepares the forced-currency intent for the quantity-inclusive amount" do
          expect(StripeFxQuote).not_to receive(:create)

          order, params = build_order(line_item_overrides: { quantity: 2, perceived_price_cents: 30_00 })
          create_args, responses = perform_with_ideal_preview(order, params, confirmation_token: "ctoken_quantity_two")

          expect(order.purchases.first.reload.displayed_price_cents).to eq(30_00)
          expect(create_args[:currency]).to eq(Currency::EUR)
          expect(create_args[:amount_cents]).to eq(30_00)
          expect(responses["unique-id-0"][:success]).to eq(true)
          expect(order.charges.last.charge_presentment.presentment_total_cents).to eq(30_00)
        end

        # Gumroad's cut is stored twice: once on the charge-level presentment row and once per
        # purchase. Payouts and refunds read the per-purchase rows, so if the allocator ever
        # dropped or double-counted a cent the seller's proceeds would silently disagree with what
        # was charged.
        #
        # Pinning only "the parts sum to the whole" would prove nothing here, because the
        # charge-level figure is computed as the sum of the per-purchase figures — that assertion
        # holds even if every purchase were given the whole charge's cut. So assert each
        # purchase's own expected value: its own fee + affiliate credit + Gumroad tax, converted
        # at its own stored rate.
        it "splits Gumroad's presentment fee share across purchases so it sums to the charge-level share" do
          other_product = create(:product, user: seller, price_currency_type: Currency::EUR, price_cents: 7_00)
          params = {
            line_items: [
              line_item,
              { uid: "unique-id-1", permalink: other_product.unique_permalink, perceived_price_cents: other_product.price_cents, quantity: 1 },
            ],
          }.merge(common_params)
          order, = Order::CreateService.new(params:).perform

          _create_args, responses = perform_with_ideal_preview(order, params, confirmation_token: "ctoken_fee_split")
          expect(responses.values).to all(include(success: true))

          charge_presentment = order.charges.last.charge_presentment
          purchases = order.purchases.map(&:reload)
          purchase_shares = purchases.map { _1.purchase_presentment.presentment_gumroad_amount_cents }

          expect(purchase_shares.size).to eq(2)

          # The value each purchase must carry on its own, independent of the charge total: the
          # same USD composition the payout path reads (Purchase#total_transaction_amount_for_gumroad_cents),
          # converted back with the rate that purchase stored.
          expected_shares = purchases.map do |purchase|
            usd_cents = purchase.fee_cents + purchase.affiliate_credit_cents + purchase.gumroad_tax_cents
            purchase.send(:usd_cents_to_currency, Currency::EUR, usd_cents, purchase.rate_converted_to_usd)
          end

          expect(expected_shares).to all(be > 0)
          expect(purchase_shares).to eq(expected_shares)
          # And a purchase can never be assigned the whole charge's cut — the bug the sum
          # assertion below is blind to.
          expect(purchase_shares).to all(be < charge_presentment.presentment_gumroad_amount_cents)
          expect(purchase_shares.sum).to eq(charge_presentment.presentment_gumroad_amount_cents)
          expect(charge_presentment.presentment_gumroad_amount_cents).to be <= charge_presentment.presentment_total_cents
        end

        # The currency basis includes this seller's free/test lines (charge_purchases), but the
        # presentment snapshot is built from the paid lines only. A free line priced in a different
        # currency therefore makes the cart non-uniform for the Element while still looking uniform
        # to the presentment call. iDEAL forces EUR by itself, so without a guard prepare would
        # build an EUR presentment for a cart whose Element mounted in USD and create an intent the
        # token can never confirm. It must fail the purchases cleanly instead.
        it "fails cleanly rather than building a forced-currency presentment when a free line is priced differently" do
          expect(StripeFxQuote).not_to receive(:create)
          free_product = create(:product, user: seller, price_currency_type: Currency::USD, price_cents: 0)
          params = {
            line_items: [
              line_item,
              { uid: "unique-id-1", permalink: free_product.unique_permalink, perceived_price_cents: 0, quantity: 1 },
            ],
          }.merge(common_params)
          order, = Order::CreateService.new(params:).perform

          create_args, responses = perform_with_ideal_preview(order, params, confirmation_token: "ctoken_free_line_currency")

          expect(create_args).to be_nil
          expect(responses["unique-id-0"][:success]).to eq(false)
          expect(order.charges.last&.charge_presentment).to be_nil
          expect(order.purchases.find { _1.link_id == product.id }.reload).to be_failed
        end

        # The same shape with the free line priced in the forced currency stays on the
        # forced-currency path — the guard must not reject a genuinely uniform cart.
        it "still prepares the forced-currency intent when the free line shares the forced currency" do
          expect(StripeFxQuote).not_to receive(:create)
          free_product = create(:product, user: seller, price_currency_type: Currency::EUR, price_cents: 0)
          params = {
            line_items: [
              line_item,
              { uid: "unique-id-1", permalink: free_product.unique_permalink, perceived_price_cents: 0, quantity: 1 },
            ],
          }.merge(common_params)
          order, = Order::CreateService.new(params:).perform

          create_args, responses = perform_with_ideal_preview(order, params, confirmation_token: "ctoken_free_line_eur")

          expect(create_args[:currency]).to eq(Currency::EUR)
          expect(create_args[:amount_cents]).to eq(15_00)
          expect(responses["unique-id-0"][:success]).to eq(true)
          expect(order.charges.last.charge_presentment.presentment_total_cents).to eq(15_00)
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

        it "keeps the USD intent when a free differently priced line makes the cart non-uniform" do
          other_product = create(:product, user: seller, price_currency_type: Currency::EUR, price_cents: 7_00)
          free_product = create(:product, user: seller, price_currency_type: Currency::USD, price_cents: 0)
          params = {
            line_items: [
              line_item,
              { uid: "unique-id-1", permalink: other_product.unique_permalink, perceived_price_cents: other_product.price_cents, quantity: 1 },
              { uid: "unique-id-2", permalink: free_product.unique_permalink, perceived_price_cents: 0, quantity: 1 },
            ],
          }.merge(common_params)
          order, = Order::CreateService.new(params:).perform

          create_args, responses = perform_with_card_preview(order, params, confirmation_token: "ctoken_mixed_free_currency")

          # The Element also sees the free USD line, so it mounts in canonical USD instead of
          # offering EUR-only methods. Prepare must preserve that same method/currency set.
          expect(create_args[:currency]).to eq(Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY)
          expect(create_args[:payment_method_types]).to eq(%w[card link])
          expect(responses.values).to all(include(success: true))
          expect(order.charges.last.charge_presentment).to be_nil
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

        it "keeps the canonical USD intent when the direct-charge account cannot offer the launched local method" do
          connect_account.update!(stripe_capabilities_snapshot: {
                                    "capabilities" => { "link_payments" => "active" },
                                    "refreshed_at" => Time.current.iso8601,
                                  })
          Feature.activate_user(:checkout_local_method_ideal, seller)
          allow(Stripe).to receive(:api_key).and_return("sk_live_currency")

          order, params = build_order
          create_args, responses = perform_with_card_preview(order, params, confirmation_token: "ctoken_card_without_ideal")

          expect(create_args[:currency]).to eq(Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY)
          expect(responses["unique-id-0"][:success]).to eq(true)
          expect(order.charges.last.charge_presentment).to be_nil
        ensure
          Feature.deactivate_user(:checkout_local_method_ideal, seller)
        end

        it "fails closed after the local-method flag rolls back from an EUR-mounted card token" do
          Feature.activate_user(:checkout_local_method_ideal, seller)
          order, params = build_order
          params[:payment_element_mount_currency] = Currency::EUR
          allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
          Feature.deactivate_user(:checkout_local_method_ideal, seller)

          create_args, responses = perform_with_card_preview(order, params, confirmation_token: "ctoken_card_after_rollback")

          expect(create_args).to be_nil
          expect(responses["unique-id-0"][:success]).to eq(false)
          expect(order.purchases.first.reload).to be_failed
        end

        # gumroad-private#1382, the dominant shape (54 of 57 affected orders). The checkout page
        # computes the element's currency when it renders and this service recomputes it when the
        # buyer pays, so a cart that becomes uniformly EUR-priced mid-session (or a seller whose
        # local-method flag turns on in between) leaves the element mounted in dollars while
        # prepare would independently conclude euros. The buyer's ConfirmationToken was minted on
        # the dollar element, so a EUR intent is one Stripe can never confirm it against: it
        # rejected the confirm in the browser with "The provided currency (eur) does not match the
        # expected currency (usd)", leaving no charge and no payment_failed webhook. The browser's
        # report is the authority — build the dollar intent it can actually pay.
        it "creates the canonical USD intent when the browser reports a USD-mounted element on this EUR cart" do
          expect(StripeFxQuote).not_to receive(:create)

          order, params = build_order
          params[:payment_element_mount_currency] = Currency::USD

          create_args, responses = perform_with_card_preview(order, params, confirmation_token: "ctoken_usd_mount_eur_cart")

          expect(create_args[:currency]).to eq(Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY)
          expect(create_args[:amount_cents]).to eq(order.purchases.sum { _1.reload.total_transaction_cents })
          expect(create_args[:stripe_fx_quote_id]).to be_nil
          expect(responses["unique-id-0"][:success]).to eq(true)
          expect(order.charges.last.charge_presentment).to be_nil
          expect(order.purchases.first.reload.purchase_presentment).to be_nil
        end

        # The method list follows the intent, not the cart's pricing. iDEAL can only charge euros,
        # so listing it on the dollar intent above would make Stripe reject the intent CREATE
        # ("Payments with ideal support the following currencies: eur") and fail the whole cart —
        # including this buyer, who paid by card. Run against a live key so the resolver offers
        # iDEAL because the seller's launch flag is on, not because test mode lists every method.
        it "drops the EUR-only local method from that USD intent so Stripe accepts the create" do
          Feature.activate_user(:checkout_local_method_ideal, seller)
          allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
          order, params = build_order
          params[:payment_element_mount_currency] = Currency::USD

          create_args, responses = perform_with_card_preview(order, params, confirmation_token: "ctoken_usd_mount_strips_ideal")

          expect(create_args[:currency]).to eq(Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY)
          expect(create_args[:payment_method_types]).to include("card")
          expect(create_args[:payment_method_types]).not_to include("ideal")
          expect(responses["unique-id-0"][:success]).to eq(true)
        ensure
          Feature.deactivate_user(:checkout_local_method_ideal, seller)
        end

        # The other direction of the same divergence, and the remaining 1 of the 57 orders: the
        # element mounted in euros while the pay-time recomputation concluded dollars. Staged the
        # way that really happens — the connected account's capability snapshot lost
        # ideal_payments after the element mounted, so the resolver no longer offers a euro-forcing
        # method and the old server-side inference gave up. Before this change that made the euro
        # token fail closed; now we honor the report and build the euro intent it can confirm,
        # because the presentment machinery gates on the seller's launch flag rather than on the
        # capability snapshot the drift touched.
        it "creates the EUR intent when the browser reports a EUR-mounted element" do
          expect(StripeFxQuote).not_to receive(:create)
          connect_account.update!(stripe_capabilities_snapshot: {
                                    "capabilities" => { "link_payments" => "active" },
                                    "refreshed_at" => Time.current.iso8601,
                                  })
          Feature.activate_user(:checkout_local_method_ideal, seller)
          allow(Stripe).to receive(:api_key).and_return("sk_live_currency")

          order, params = build_order
          params[:payment_element_mount_currency] = Currency::EUR

          create_args, responses = perform_with_card_preview(order, params, confirmation_token: "ctoken_eur_mount_reported")

          expect(create_args[:currency]).to eq(Currency::EUR)
          expect(create_args[:amount_cents]).to eq(15_00)
          expect(responses["unique-id-0"][:success]).to eq(true)
          expect(order.charges.last.charge_presentment.presentment_currency).to eq(Currency::EUR)
        ensure
          Feature.deactivate_user(:checkout_local_method_ideal, seller)
        end

        # The browser is trusted about WHICH currency its element used, never about whether that
        # currency is chargeable. A currency no payment method forces could only come from a stale
        # or crafted client, and we have no presentment machinery to build an intent in it — fail
        # the order cleanly rather than create an intent nobody can confirm.
        it "fails closed when the reported mount currency is one we can't build an intent in" do
          order, params = build_order
          params[:payment_element_mount_currency] = "gbp"

          create_args, responses = perform_with_card_preview(order, params, confirmation_token: "ctoken_unsupported_mount")

          expect(create_args).to be_nil
          expect(responses["unique-id-0"][:success]).to eq(false)
          expect(order.purchases.first.reload).to be_failed
        end

        # A method that can only charge in one currency still decides for itself: the buyer picked
        # iDEAL, so the intent must be in euros no matter what the element reported, because that
        # is the only currency an iDEAL confirmation can settle in. This example cannot fail
        # against the old code — the old code never consulted the report for such a method either.
        # It pins the BRANCH ORDER of the new decision: an implementation that let the report
        # override the method's own forced currency would build a dollar intent here and fail.
        it "keeps the forced-currency intent for an iDEAL token even when the browser reports USD" do
          order, params = build_order
          params[:payment_element_mount_currency] = Currency::USD

          create_args, responses = perform_with_ideal_preview(order, params, confirmation_token: "ctoken_ideal_usd_report")

          expect(create_args[:currency]).to eq(Currency::EUR)
          expect(create_args[:payment_method_types]).to include("ideal")
          expect(responses["unique-id-0"][:success]).to eq(true)
        end
      end

      # iDEAL can only confirm against a euro intent. When the seller is not enabled for
      # buyer-currency charging there is no presentment machinery, and a USD fallback cannot
      # confirm the token — fail closed instead of creating an unconfirmable intent.
      it "fails an iDEAL token closed rather than building an unconfirmable USD intent when the flag is off" do
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        expect(StripeFxQuote).not_to receive(:create)

        order, params = build_order
        create_args, responses = perform_with_ideal_preview(order, params, confirmation_token: "ctoken_flag_off")

        expect(create_args).to be_nil
        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.purchases.first.reload).to be_failed
        expect(order.charges.last&.charge_presentment).to be_nil
      end

      # Same fail-closed for a card token minted on a euro-mounted element after the flag
      # rolled back: no presentment machinery, and the euro token cannot confirm USD.
      it "fails a EUR-mounted token closed rather than building an unconfirmable USD intent when the flag is off" do
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)

        order, params = build_order
        params[:payment_element_mount_currency] = Currency::EUR

        preview = Stripe::StripeObject.construct_from(type: "card", card: { country: "NL" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          instance_double(StripeChargeIntent, id: "pi_flag_off_eur", client_secret: "secret")
        end

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_flag_off_eur_mount").perform

        expect(create_args).to be_nil
        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.purchases.first.reload).to be_failed
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

    context "with a direct-listed client-confirm card" do
      let(:seller) { create(:user, check_merchant_account_is_linked: true, disable_buyer_local_currency: false) }
      let(:product) { create(:product, user: seller, price_currency_type: Currency::CAD, price_cents: 15_00) }
      let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }

      before do
        connect_account.update!(stripe_capabilities_snapshot: {
                                  "capabilities" => { "link_payments" => "active" },
                                  "refreshed_at" => Time.current.iso8601,
                                })
        Feature.activate_user(:buyer_local_currency, seller)
        Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        Feature.activate_user(Checkout::BuyerCurrencyEligibility::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
        allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
        allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      end

      after do
        Feature.deactivate_user(:buyer_local_currency, seller)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
      end

      def perform_with_direct_listed_card(order, params, mount_currency: Currency::CAD)
        params[:payment_details_source] = PurchasePaymentFlow::PAYMENT_ELEMENT
        params[:payment_element_mount_currency] = mount_currency
        preview = Stripe::StripeObject.construct_from(type: "card", card: { country: "CA" })
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_direct_cad", client_secret: "pi_direct_cad_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_direct_cad").perform
        [create_args, responses]
      end

      it "prepares the intent for the displayed CAD amount and persists quote-less presentment rows" do
        order, params = build_order
        purchase = order.purchases.first
        purchase.update!(displayed_price_cents: 15_00,
                         displayed_price_currency_type: Currency::CAD,
                         rate_converted_to_usd: BigDecimal("0.8"))

        create_args, responses = perform_with_direct_listed_card(order, params)

        expect(create_args[:currency]).to eq(Currency::CAD)
        expect(create_args[:amount_cents]).to eq(15_00)
        expect(create_args[:stripe_fx_quote_id]).to be_nil
        expect(create_args[:idempotency_key]).to match(/buyer-currency-intent-.+-cad_ctoken_direct_cad/)
        expect(responses["unique-id-0"][:success]).to eq(true)
        expect(order.charges.last.charge_presentment)
          .to have_attributes(presentment_currency: Currency::CAD, presentment_total_cents: 15_00, stripe_fx_quote_id: nil)
      end

      it "keeps the canonical USD intent when the Element reports that it displayed USD" do
        order, params = build_order
        expect(Charge::DirectListedPresentment).not_to receive(:new)

        create_args, responses = perform_with_direct_listed_card(order, params, mount_currency: Currency::USD)

        expect(create_args[:currency]).to eq(Currency::USD)
        expect(responses["unique-id-0"][:success]).to eq(true)
        expect(order.charges.last.charge_presentment).to be_nil
      end

      it "fails closed without creating a USD intent when direct-listed persistence fails" do
        order, params = build_order
        order.purchases.first.update!(displayed_price_cents: 15_00,
                                      displayed_price_currency_type: Currency::CAD,
                                      rate_converted_to_usd: BigDecimal("0.8"))
        allow(ErrorNotifier).to receive(:notify)
        allow(Charge::PresentmentOrchestrator).to receive(:persist!).and_raise("presentment persist failed")

        create_args, responses = perform_with_direct_listed_card(order, params)

        expect(create_args).to be_nil
        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.purchases.first.reload).to be_failed
      end
    end

    context "with a method-forced UPI payment method" do
      let(:seller) { create(:user, check_merchant_account_is_linked: true, disable_buyer_local_currency: false) }
      let(:product) { create(:product, user: seller, price_currency_type: Currency::INR, price_cents: 1_499_00) }
      let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }

      before do
        connect_account.update!(stripe_capabilities_snapshot: {
                                  "capabilities" => { "link_payments" => "active", "upi_payments" => "active" },
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

      def perform_with_upi_preview(order, params)
        preview = Stripe::StripeObject.construct_from(type: "upi", upi: {}, card: nil)
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_upi", client_secret: "pi_upi_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_upi").perform
        [create_args, responses]
      end

      it "prepares a PPP-discounted Indian purchase using the UPI region lock as its funding country" do
        product.update!(purchasing_power_parity_disabled: false)
        seller.update!(purchasing_power_parity_enabled: true)
        PurchasingPowerParityService.new.set_factor("IN", 0.5)
        order, params = build_order
        order.purchases.each do |purchase|
          purchase.update!(ip_country: "India", is_purchasing_power_parity_discounted: true)
        end

        create_args, responses = perform_with_upi_preview(order, params)

        expect(responses["unique-id-0"][:success]).to eq(true), responses.inspect
        expect(create_args[:currency]).to eq(Currency::INR)
        expect(create_args[:payment_method_types]).to include("upi")
        expect(order.purchases.first.reload.card_country).to eq("IN")
      ensure
        PurchasingPowerParityService.new.set_factor("IN", 1)
      end

      it "rejects a UPI token when the server-owned buyer country is outside India" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }

        create_args, responses = perform_with_upi_preview(order, params)

        expect(create_args).to be_nil
        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.charges).to be_empty
        expect(order.purchases.first.reload).to be_failed
      end

      # The USD remount path exists so UPI can appear on a USD listing. Presentment
      # must stay required: a USD fallback cannot confirm a token minted in INR.
      context "on a USD-priced cart remounted in INR for a seller who hid local-currency display" do
        let(:seller) { create(:user, check_merchant_account_is_linked: true, disable_buyer_local_currency: true) }
        let(:product) { create(:product, user: seller, price_cents: 19_99) }
        let(:quote) do
          StripeFxQuote::Quote.new(id: "fxq_upi_usd", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("83.0"))
        end

        before { allow(StripeFxQuote).to receive(:create).and_return(quote) }

        it "fails closed when UPI is selected without the displayed quote" do
          order, params = build_order
          order.purchases.each { _1.update!(ip_country: "India") }
          expect(StripeFxQuote).not_to receive(:create)

          create_args, responses = perform_with_upi_preview(order, params)

          expect(create_args).to be_nil
          expect(responses["unique-id-0"][:success]).to eq(false)
          expect(order.purchases.first.reload).to be_failed
        end

        it "fails closed when INR presentment cannot be recreated after a UPI selection" do
          allow_any_instance_of(Charge::MethodForcedPresentment).to receive(:perform).and_return(nil)

          order, params = build_order
          order.purchases.each { _1.update!(ip_country: "India") }

          create_args, responses = perform_with_upi_preview(order, params)

          expect(create_args).to be_nil
          expect(responses["unique-id-0"][:success]).to eq(false)
          expect(order.purchases.first.reload).to be_failed
        end

        it "reuses the displayed INR quote instead of minting a second rate" do
          order, params = build_order
          params = params.merge(payment_element_mount_currency: Currency::INR, buyer_currency_quote: "displayed-inr-quote")
          order.purchases.each { _1.update!(ip_country: "India") }
          locked = instance_double(
            Checkout::BuyerCurrencyQuote::Result,
            stripe_fx_quote_id: "fxq_displayed_upi",
            fx_rate: BigDecimal("0.012048"),
            stripe_fx_quote_expires_at: 30.minutes.from_now,
            charge_presentment_total_cents: 1_659_17
          )
          allow(Checkout::BuyerCurrencyQuote).to receive(:verify!).and_return(locked)
          expect(StripeFxQuote).not_to receive(:create)

          create_args, responses = perform_with_upi_preview(order, params)

          expect(responses["unique-id-0"][:success]).to eq(true), responses.inspect
          expect(create_args[:currency]).to eq(Currency::INR)
          expect(create_args[:stripe_fx_quote_id]).to eq("fxq_displayed_upi")
          expect(create_args[:amount_cents]).to eq(1_659_17)
          expect(Checkout::BuyerCurrencyQuote).to have_received(:verify!).with(hash_including(token: "displayed-inr-quote", currency: Currency::INR))
        end

        it "prepares the INR intent when the buyer selected card on the remounted element" do
          order, params = build_order
          params = params.merge(payment_element_mount_currency: Currency::INR, buyer_currency_quote: "displayed-inr-quote")
          order.purchases.each { _1.update!(ip_country: "India") }
          locked = instance_double(
            Checkout::BuyerCurrencyQuote::Result,
            stripe_fx_quote_id: "fxq_displayed_card",
            fx_rate: BigDecimal("0.012048"),
            stripe_fx_quote_expires_at: 30.minutes.from_now,
            charge_presentment_total_cents: 1_659_17
          )
          allow(Checkout::BuyerCurrencyQuote).to receive(:verify!).and_return(locked)
          expect(StripeFxQuote).not_to receive(:create)

          preview = Stripe::StripeObject.construct_from(type: "card", card: { country: "IN" })
          allow(Stripe::ConfirmationToken).to receive(:retrieve)
            .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

          charge_intent = instance_double(StripeChargeIntent, id: "pi_card_inr", client_secret: "pi_card_inr_secret")
          create_args = nil
          allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
            create_args = kwargs
            charge_intent
          end

          responses = described_class.new(order:, params:, confirmation_token: "ctoken_card_inr").perform

          expect(responses["unique-id-0"][:success]).to eq(true), responses.inspect
          expect(create_args[:currency]).to eq(Currency::INR)
          expect(create_args[:payment_method_types]).to include("card")
        end
      end
    end


    context "with a paid-upfront UPI Autopay membership" do
      let(:seller) { create(:user, disable_buyer_local_currency: false) }
      let(:product) do
        create(:membership_product, user: seller, price_currency_type: Currency::INR, price_cents: 100_000)
      end
      let!(:platform_account) do
        MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
          create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                    charge_processor_merchant_id: nil)
      end
      let(:line_item) do
        {
          uid: "unique-id-0",
          permalink: product.unique_permalink,
          perceived_price_cents: 100_000,
          quantity: 1,
          price_id: product.prices.alive.first.external_id,
        }
      end

      before do
        Feature.activate_user(:buyer_local_currency, seller)
        Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)
        Feature.activate(Checkout::PaymentMethodResolver::UPI_RECURRING_SERVICING_FEATURE)
        Feature.activate_user(Checkout::PaymentMethodResolver::UPI_RECURRING_LAUNCH_FEATURE, seller)
        Feature.activate_user(:checkout_local_method_upi, seller)
        allow(Stripe).to receive(:api_key).and_return("sk_test_upi_autopay")
      end

      after do
        Feature.deactivate_user(:buyer_local_currency, seller)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)
        Feature.deactivate(Checkout::PaymentMethodResolver::UPI_RECURRING_SERVICING_FEATURE)
        Feature.deactivate_user(Checkout::PaymentMethodResolver::UPI_RECURRING_LAUNCH_FEATURE, seller)
        Feature.deactivate_user(:checkout_local_method_upi, seller)
      end

      def prepare_upi_autopay(order, params, payment_method_type: "upi")
        preview = if payment_method_type == "card"
          Stripe::StripeObject.construct_from(type: "card", card: { country: "IN" })
        elsif payment_method_type == "upi"
          Stripe::StripeObject.construct_from(type: "upi", upi: {}, card: nil)
        else
          Stripe::StripeObject.construct_from(type: payment_method_type, payment_method_type.to_sym => {}, card: nil)
        end
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_upi_autopay", client_secret: "pi_upi_autopay_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        responses = described_class.new(order:, params:, confirmation_token: "ctoken_upi_autopay").perform
        [create_args, responses]
      end

      it "creates a customer-backed INR intent with card + UPI and recurring authorization options" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "India") }

        create_args, responses = prepare_upi_autopay(order, params)

        expect(responses["unique-id-0"][:success]).to eq(true), responses.inspect
        expect(create_args).to include(
          merchant_account: platform_account,
          currency: Currency::INR,
          payment_method_types: %w[card upi],
          setup_future_usage: "off_session"
        )
        expect(create_args[:customer_params]).to include(email: "buyer@example.com")
        expect(create_args[:customer_idempotency_key])
          .to eq("upi_autopay_customer_#{order.external_id}_#{order.created_at.to_i}_#{order.created_at.usec}")
        expect(create_args[:customer_idempotency_key]).not_to include("ctoken_upi_autopay")
        mandate_options = create_args.dig(:payment_method_options, :upi, :mandate_options)
        expect(mandate_options).to include(
          amount_type: "maximum",
          description: described_class::UPI_MANDATE_DESCRIPTION
        )
        expect(mandate_options[:amount]).to be_between(1, Checkout::PaymentMethodResolver::UPI_RECURRING_MAX_INR_CENTS)
        expect(create_args.dig(:metadata, StripeChargeProcessor::UPI_RECURRING_MAX_AMOUNT_METADATA_KEY))
          .to eq(mandate_options[:amount].to_s)
        expect(order.purchases.first.reload.card_type).to eq(CardType::UPI)
      end

      it "rejects registration before Stripe when renewal servicing is disabled" do
        Feature.deactivate(Checkout::PaymentMethodResolver::UPI_RECURRING_SERVICING_FEATURE)
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "India") }

        create_args, responses = prepare_upi_autopay(order, params)

        expect(create_args).to be_nil
        expect(responses["unique-id-0"][:success]).to be(false)
        expect(order.charges).to be_empty
      end

      it "preserves the Indian-card e-mandate contract when card is selected on the same element" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "India") }
        allow_any_instance_of(Purchase).to receive(:mandate_maximum_amount_cents).and_return(2_000_000)

        create_args, responses = prepare_upi_autopay(order, params, payment_method_type: "card")

        expect(responses["unique-id-0"][:success]).to eq(true), responses.inspect
        expect(create_args[:payment_method_types]).to eq(["card"])
        expect(create_args[:metadata]).not_to have_key(StripeChargeProcessor::UPI_RECURRING_MAX_AMOUNT_METADATA_KEY)
        expect(create_args.dig(:payment_method_options, :upi)).to be_nil
        mandate_options = create_args.dig(:payment_method_options, :card, :mandate_options)
        expect(mandate_options).to include(
          amount_type: "maximum",
          currency: Currency::INR,
          interval: "sporadic",
          supported_types: ["india"]
        )
        expect(mandate_options[:amount]).to be > Checkout::PaymentMethodResolver::UPI_RECURRING_MAX_INR_CENTS
      end

      it "rejects a crafted Link token before creating a recurring intent" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "India") }

        create_args, responses = prepare_upi_autopay(order, params, payment_method_type: "link")

        expect(create_args).to be_nil
        expect(responses["unique-id-0"][:success]).to be(false)
        expect(order.charges).to be_empty
        expect(order.purchases.first.reload).to be_failed
      end

      it "fails before Stripe when the maximum permitted debit exceeds INR 15,000" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "India") }
        allow_any_instance_of(Purchase).to receive(:mandate_maximum_amount_cents).and_return(2_000_000)

        create_args, responses = prepare_upi_autopay(order, params)

        expect(create_args).to be_nil
        expect(responses["unique-id-0"]).to include(
          success: false,
          error_code: PurchaseErrorCode::UPI_AUTOPAY_AMOUNT_OUTSIDE_WINDOW,
          error_message: described_class::UPI_AUTOPAY_AMOUNT_INELIGIBLE_MESSAGE
        )
        expect(order.purchases.first.reload).to be_failed
        expect(ChargePresentment.count).to eq(0)
        expect(PurchasePresentment.count).to eq(0)
      end

      it "rejects a crafted gift before creating the recurring intent" do
        params = { line_items: [line_item] }.merge(common_params).merge(
          is_gift: "true",
          giftee_email: "giftee@example.com",
          gift_note: "Enjoy!"
        )
        order, = Order::CreateService.new(params:).perform
        order.purchases.each { _1.update!(ip_country: "India") }
        purchase = order.purchases.find(&:is_gift_sender_purchase?)

        create_args, responses = prepare_upi_autopay(order, params)

        expect(create_args).to be_nil
        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.charges).to be_empty
        expect(purchase.reload).to be_failed
      end

      it "rejects a seller-owned Stripe account before creating the recurring intent" do
        create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_upi_autopay_destination")
        seller.merchant_accounts.reset
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "India") }

        create_args, responses = prepare_upi_autopay(order, params)

        expect(create_args).to be_nil
        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.charges).to be_empty
        expect(order.purchases.first.reload).to be_failed
      end
    end

    context "with a method-forced Pix payment method" do
      let(:seller) { create(:user, check_merchant_account_is_linked: true, disable_buyer_local_currency: false) }
      let(:product) { create(:product, user: seller, price_currency_type: Currency::BRL, price_cents: 100_00) }
      let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }

      before do
        connect_account.update!(stripe_capabilities_snapshot: {
                                  "capabilities" => { "link_payments" => "active", "pix_payments" => "active" },
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

      def perform_with_preview(order, params, preview:, confirmation_token: "ctoken_pix")
        allow(Stripe::ConfirmationToken).to receive(:retrieve)
          .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))

        charge_intent = instance_double(StripeChargeIntent, id: "pi_pix", client_secret: "pi_pix_secret")
        create_args = nil
        allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
          create_args = kwargs
          charge_intent
        end

        responses = described_class.new(order:, params:, confirmation_token:).perform
        [create_args, responses]
      end

      def perform_with_pix_preview(order, params, confirmation_token: "ctoken_pix")
        preview = Stripe::StripeObject.construct_from(type: "pix", pix: {}, card: nil)
        perform_with_preview(order, params, preview:, confirmation_token:)
      end

      it "creates the BRL intent with Pix's create-time options, charging the buyer exactly the listed price and adding no IOF on this direct charge" do
        # A genuinely Brazilian connected account — the domestic case. The factory leaves country
        # nil, which is a DIFFERENT lane (see the non-Brazilian example below), so set it here
        # rather than relying on the default.
        connect_account.update!(country: "BR")

        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "Brazil") }

        create_args, responses = perform_with_pix_preview(order, params)

        expect(responses["unique-id-0"][:success]).to eq(true), responses.inspect
        expect(create_args[:currency]).to eq(Currency::BRL)
        expect(create_args[:payment_method_types]).to include("pix")
        expect(create_args[:amount_cents]).to eq(100_00)
        # The charge is created on the seller's own Brazilian Stripe account, so the payment never
        # leaves Brazil: no foreign exchange, therefore no IOF for Stripe to price.
        # amount_includes_iof is left off entirely rather than sent — asking Stripe to price a tax
        # that does not apply is at best meaningless, and an option Stripe does not accept fails
        # the whole intent create, taking card down with it for that checkout.
        expect(create_args[:payment_method_options]).to eq(
          pix: { expires_after_seconds: described_class::PIX_EXPIRES_AFTER_SECONDS }
        )

        # The method must be seeded onto the purchase before fees are recomputed, so that fee logic
        # can see it is a Pix payment at all. Assert that first, independently of the fee amount.
        purchase = order.purchases.first.reload
        expect(purchase.card_type).to eq(CardType::PIX)

        # Gumroad charges a Brazilian connected account no fee at all (calculate_fees returns early
        # for is_a_brazilian_stripe_connect_account?), so there is no IOF component to look for and
        # nothing else either. The IOF-charging path is covered on a Gumroad-managed account in
        # spec/models/purchase/purchase_process_spec.rb ("Pix IOF fee").
        expect(purchase.charged_using_gumroad_merchant_account?).to eq(false)
        expect(purchase.send(:pix_iof_fee_per_thousand)).to eq(0)
        expect(purchase.fee_cents).to eq(0)
      end

      # The other direct-charge lane, and the reason the option's gate is keyed on the account's
      # COUNTRY rather than on who owns it. Nothing restricts Pix to Brazilian connected accounts —
      # the resolver's BR lock is on the buyer, and the only per-account condition is the Stripe
      # capability snapshot — so a non-Brazilian connected account with pix_payments active takes a
      # payment that DOES leave Brazil. IOF applies, so the option must still be sent, even though
      # the money never touches a Gumroad-held balance and there is no Gumroad cost to bill back.
      it "still sends amount_includes_iof on a direct charge to a NON-Brazilian connected account, but bills no IOF fee" do
        connect_account.update!(country: "US")

        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "Brazil") }

        create_args, responses = perform_with_pix_preview(order, params, confirmation_token: "ctoken_pix_non_br")

        expect(responses["unique-id-0"][:success]).to eq(true), responses.inspect
        expect(create_args[:currency]).to eq(Currency::BRL)
        expect(create_args[:payment_method_types]).to include("pix")
        expect(create_args[:payment_method_options]).to eq(
          pix: {
            expires_after_seconds: described_class::PIX_EXPIRES_AFTER_SECONDS,
            amount_includes_iof: described_class::PIX_AMOUNT_INCLUDES_IOF,
          }
        )

        purchase = order.purchases.first.reload
        expect(purchase.card_type).to eq(CardType::PIX)
        # Cross-border, so the tax exists and the option is sent — but the charge settles into the
        # seller's own account, so Gumroad absorbed nothing and recovers nothing. The two gates
        # answering differently here is the intended behaviour, not a drift.
        expect(purchase.charged_using_gumroad_merchant_account?).to eq(false)
        expect(purchase.send(:pix_iof_fee_per_thousand)).to eq(0)
      end

      # The counterpart to the direct-charge cases above: on a Gumroad-held account the money leaves
      # Brazil, the payment is cross-border, IOF applies, and the option must be sent — otherwise
      # Stripe's default marks the buyer's amount up by the tax and the banking-app total stops
      # matching the price checkout quoted. This is what all Pix traffic looks like today.
      it "sends amount_includes_iof and bills the IOF fee when the Pix charge is created on a Gumroad-held account" do
        connect_account.mark_deleted!
        seller.reload

        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "Brazil") }

        create_args, responses = perform_with_pix_preview(order, params, confirmation_token: "ctoken_pix_gumroad")

        expect(responses["unique-id-0"][:success]).to eq(true), responses.inspect
        expect(create_args[:currency]).to eq(Currency::BRL)
        expect(create_args[:payment_method_types]).to include("pix")
        expect(create_args[:payment_method_options]).to eq(
          pix: {
            expires_after_seconds: described_class::PIX_EXPIRES_AFTER_SECONDS,
            amount_includes_iof: described_class::PIX_AMOUNT_INCLUDES_IOF,
          }
        )

        purchase = order.purchases.first.reload
        expect(purchase.card_type).to eq(CardType::PIX)
        expect(purchase.charged_using_gumroad_merchant_account?).to eq(true)
        expect(purchase.send(:pix_iof_fee_per_thousand)).to eq(Purchase::PIX_IOF_FEE_PER_THOUSAND)
      end

      it "sends no payment_method_options and no IOF fee for a card confirm on the same BRL element" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "Brazil") }

        preview = Stripe::StripeObject.construct_from(type: "card", card: { country: "BR" })
        create_args, responses = perform_with_preview(order, params, preview:, confirmation_token: "ctoken_card_brl")

        expect(responses["unique-id-0"][:success]).to eq(true), responses.inspect
        expect(create_args[:currency]).to eq(Currency::BRL)
        expect(create_args[:payment_method_options]).to be_nil

        purchase = order.purchases.first.reload
        expect(purchase.card_type).to be_nil
        expected_variable_fee_cents = (purchase.price_cents * Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND / 1000.0).round
        expect(purchase.fee_cents).to eq(expected_variable_fee_cents + Purchase::GUMROAD_FIXED_FEE_CENTS)
      end

      # Stripe caps a single Pix payment at 3,000 USD and validates it against the intent's final
      # amount. The bound is quoted in USD, so it is checked against the canonical USD total
      # (amount_cents), which is already denominated in USD — no FX conversion can drift the
      # verdict. Checkout's own $5,000 purchase maximum still admits carts above Pix's $3,000
      # ceiling: with the BRL rate pinned to 5.0 — pinned because the shared Redis rate cache
      # varies by environment (backup-rates fixture locally, the preview-QA seed on a fresh CI
      # Redis) — R$20,000 converts to exactly $4,000: above the Pix ceiling, under the purchase
      # max, and comfortably above the BRL floor, so this failure isolates the ceiling.
      it "fails closed with PIX_AMOUNT_OUTSIDE_WINDOW when the canonical USD total exceeds Stripe's Pix ceiling, leaving no orphaned presentment rows" do
        currency_namespace = Redis::Namespace.new(:currencies, redis: $redis)
        original_brl_rate = currency_namespace.get("BRL")
        currency_namespace.set("BRL", "5.0")

        big_product = create(:product, user: seller, price_currency_type: Currency::BRL, price_cents: 20_000_00)
        params = {
          line_items: [{ uid: "unique-id-0", permalink: big_product.unique_permalink, perceived_price_cents: 20_000_00, quantity: 1 }]
        }.merge(common_params)
        order, order_responses = Order::CreateService.new(params:).perform
        expect(order_responses.values).to all(include(success: true))
        order.purchases.each { _1.update!(ip_country: "Brazil") }

        create_args, responses = perform_with_pix_preview(order, params, confirmation_token: "ctoken_pix_big")

        expect(create_args).to be_nil
        response = responses["unique-id-0"]
        expect(response[:success]).to eq(false)
        # Deterministic rejection: retrying Pix on this cart can never succeed, so the buyer gets
        # the actionable "choose a different payment method" message, not the generic retry one.
        expect(response[:error_message]).to eq(described_class::PIX_AMOUNT_INELIGIBLE_MESSAGE)
        expect(response[:error_code]).to eq(PurchaseErrorCode::PIX_AMOUNT_OUTSIDE_WINDOW)
        expect(order.purchases.first.reload).to be_failed
        # The BRL snapshot was persisted before the gate ran (the gate needs its BRL total), and
        # belongs to an intent that will never exist — it must not be orphaned.
        expect(ChargePresentment.count).to eq(0)
        expect(PurchasePresentment.count).to eq(0)
      ensure
        original_brl_rate.present? ? currency_namespace.set("BRL", original_brl_rate) : currency_namespace.del("BRL")
      end

      # Stripe's floor is 0.50 BRL, checked against the BRL presentment total — the figure
      # natively in the floor's own currency. No real cart can price below it (Gumroad's minimum
      # BRL price is R$5.33), so force the presentment total under the floor while keeping the
      # genuinely persisted rows: this proves both the BRL-native comparison and that the gate
      # cleans up the snapshot it strands. The R$100 cart's USD total (~$56) is well inside the
      # ceiling, so this failure isolates the floor.
      it "fails closed with PIX_AMOUNT_OUTSIDE_WINDOW when the BRL presentment total is below Stripe's Pix floor, leaving no orphaned presentment rows" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "Brazil") }

        allow_any_instance_of(Charge::MethodForcedPresentment).to receive(:perform).and_wrap_original do |original|
          result = original.call
          result.presentment_total_cents = Checkout::PaymentMethodResolver::PIX_MIN_BRL_CHARGE_CENTS - 1
          result
        end

        create_args, responses = perform_with_pix_preview(order, params, confirmation_token: "ctoken_pix_small")

        expect(create_args).to be_nil
        response = responses["unique-id-0"]
        expect(response[:success]).to eq(false)
        expect(response[:error_message]).to eq(described_class::PIX_AMOUNT_INELIGIBLE_MESSAGE)
        expect(response[:error_code]).to eq(PurchaseErrorCode::PIX_AMOUNT_OUTSIDE_WINDOW)
        expect(order.purchases.first.reload).to be_failed
        expect(ChargePresentment.count).to eq(0)
        expect(PurchasePresentment.count).to eq(0)
      end

      # A Pix cart always produces a BRL presentment (Pix forces BRL), so a missing one means our own
      # presentment layer failed, not that the buyer's basket is priced outside Stripe's window. The
      # gate must still fail closed, but it must not stamp PIX_AMOUNT_OUTSIDE_WINDOW — that code is
      # the metric for how often real carts fall outside the window, and mixing an internal fault
      # into it would make the number mean two different things.
      it "fails closed with the generic error, not PIX_AMOUNT_OUTSIDE_WINDOW, when no BRL presentment exists at all" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "Brazil") }

        # The seller's buyer-currency flags have to be off for this example to reach the Pix gate
        # at all. With them on, client_confirm_presentment_required? is true and
        # prepare_unconfirmed_charge fails the order on its own nil-presentment guard several lines
        # earlier, which produces this same generic error and would let the example pass without
        # the gate ever running. Flags off is also the only way a Pix token genuinely arrives with
        # no presentment in production: a stale token confirming after the seller's local-method
        # rollout was rolled back.
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        Feature.deactivate_user(:buyer_local_currency, seller)

        allow_any_instance_of(Charge::MethodForcedPresentment).to receive(:perform).and_return(nil)

        create_args, responses = perform_with_pix_preview(order, params, confirmation_token: "ctoken_pix_no_presentment")

        expect(create_args).to be_nil
        response = responses["unique-id-0"]
        expect(response[:success]).to eq(false)
        expect(response[:error_message]).to eq(described_class::GENERIC_CHARGE_ERROR)
        expect(response[:error_code]).to eq(PurchaseErrorCode::PROCESSING_ERROR)
        expect(response[:error_code]).not_to eq(PurchaseErrorCode::PIX_AMOUNT_OUTSIDE_WINDOW)
        expect(order.purchases.first.reload).to be_failed
        expect(ChargePresentment.count).to eq(0)
        expect(PurchasePresentment.count).to eq(0)
      end

      it "rejects a Pix token when the server-owned buyer country is outside Brazil" do
        order, params = build_order
        order.purchases.each { _1.update!(ip_country: "United States") }

        create_args, responses = perform_with_pix_preview(order, params)

        expect(create_args).to be_nil
        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.charges).to be_empty
        expect(order.purchases.first.reload).to be_failed
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
