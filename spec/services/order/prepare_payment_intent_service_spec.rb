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

      it "fails the purchases without creating an intent" do
        order, params = build_order

        responses = described_class.new(order:, params:, confirmation_token: nil).perform

        expect(responses["unique-id-0"][:success]).to eq(false)
        expect(order.charges).to be_empty
        expect(order.purchases.first.reload).to be_failed
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
