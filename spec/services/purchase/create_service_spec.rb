# frozen_string_literal: false

include CurrencyHelper

describe Purchase::CreateService, :vcr do
  let(:user) { create(:user) }
  let(:email) { "sahil@gumroad.com" }
  let(:buyer) { create(:user, email:) }
  let(:zip_code) { "12345" }

  let(:price) { 600 }
  let(:max_purchase_count) { nil }
  let(:product) { create(:product, user:, price_cents: price, max_purchase_count:) }
  let(:subscription_product) { create(:subscription_product, user:, price_cents: price) }
  let(:browser_guid) { SecureRandom.uuid }
  let(:successful_card_chargeable) do
    CardParamsHelper.build_chargeable(
      StripePaymentMethodHelper.success.with_zip_code(zip_code).to_stripejs_params,
      browser_guid
    )
  end
  let(:successful_paypal_chargeable) { build(:paypal_chargeable) }
  let(:failed_chargeable) do
    CardParamsHelper.build_chargeable(
      StripePaymentMethodHelper.decline.to_stripejs_params,
      browser_guid
    )
  end
  let(:base_params) do
    {
      purchase: {
        email:,
        quantity: 1,
        perceived_price_cents: price,
        ip_address: "0.0.0.0",
        session_id: "a107d0b7ab5ab3c1eeb7d3aaf9792977",
        is_mobile: false,
        browser_guid:
      }
    }
  end
  let(:params) do
    base_params[:purchase].merge!(
      card_data_handling_mode: "stripejs.0",
      credit_card_zipcode: zip_code,
      chargeable: successful_card_chargeable
    )
    base_params
  end
  let(:paypal_params) do
    base_params[:purchase].merge!(
      chargeable: successful_paypal_chargeable
    )
    base_params
  end
  let(:native_paypal_params) do
    base_params[:purchase].merge!(
      chargeable: build(:native_paypal_chargeable)
    )
    base_params
  end
  let(:base_subscription_params) do
    base_params[:purchase].delete(:perceived_price_cents)
    base_params[:price_id] = subscription_product.prices.alive.first.external_id
    base_params
  end
  let(:subscription_params) do
    base_subscription_params[:purchase].merge!(
      card_data_handling_mode: "stripejs.0",
      credit_card_zipcode: zip_code,
      chargeable: successful_card_chargeable
    )
    base_subscription_params
  end
  let(:base_preorder_params) do
    base_params[:purchase][:is_preorder_authorization] = "true"
    base_params
  end
  let(:preorder_params) do
    base_preorder_params[:purchase].merge!(
      card_data_handling_mode: "stripejs.0",
      credit_card_zipcode: zip_code,
      chargeable: successful_card_chargeable
    )
    base_preorder_params
  end
  let(:paypal_preorder_params) do
    base_preorder_params[:purchase].merge!(
      chargeable: successful_paypal_chargeable
    )
    base_preorder_params
  end
  let(:shipping_params) do
    params[:purchase].merge!(
      full_name: "Edgar Gumstein",
      street_address: "123 Gum Road",
      country: "LY",
      state: "CA",
      city: "San Francisco",
      zip_code: "94117"
    )
    params
  end

  it "creates a purchase and sets the proper state" do
    expect do
      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase.purchase_state).to eq "successful"
      expect(purchase.card_country).to be_present
      expect(purchase.stripe_fingerprint).to be_present
      expect(purchase.reload.succeeded_at).to be_present
      expect(purchase.ip_address).to eq "0.0.0.0"
      expect(purchase.session_id).to eq "a107d0b7ab5ab3c1eeb7d3aaf9792977"
      expect(purchase.card_data_handling_mode).to eq CardDataHandlingMode::TOKENIZE_VIA_STRIPEJS
      expect(purchase.purchase_refund_policy.title).to eq(product.user.refund_policy.title)
      expect(purchase.purchase_refund_policy.fine_print).to eq(product.user.refund_policy.fine_print)
    end.to change { Purchase.count }.by 1
  end

  it "sets the buyer when provided" do
    purchase, _ = Purchase::CreateService.new(
      product:,
      params:,
      buyer:
    ).perform

    expect(purchase.purchaser).to eq buyer
  end

  context "when the product has a product refund policy enabled" do
    before do
      product.user.update!(refund_policy_enabled: false)
      product.update!(product_refund_policy_enabled: true)
    end

    context "when the refund policy has a fine print" do
      let!(:refund_policy) do
        create(:product_refund_policy, fine_print: "This is a product-level refund policy", product:, seller: user)
      end

      it "saves product refund policy fine print on purchase" do
        purchase, _ = Purchase::CreateService.new(
          product:,
          params:,
          buyer:
        ).perform

        expect(purchase.purchase_refund_policy.max_refund_period_in_days).to eq(30)
        expect(purchase.purchase_refund_policy.title).to eq("30-day money back guarantee")
        expect(purchase.purchase_refund_policy.fine_print).to eq("This is a product-level refund policy")
      end

      context "when the account-level refund policy is enabled" do
        before do
          user.refund_policy.update!(fine_print: "This is an account-level refund policy")
          user.update!(refund_policy_enabled: true)
        end

        it "saves the seller-level refund policy" do
          purchase, _ = Purchase::CreateService.new(
            product:,
            params:,
            buyer:
          ).perform

          expect(purchase.purchase_refund_policy.max_refund_period_in_days).to eq(30)
          expect(purchase.purchase_refund_policy.title).to eq("30-day money back guarantee")
          expect(purchase.purchase_refund_policy.fine_print).to eq("This is an account-level refund policy")
        end

        context "when seller_refund_policy_disabled_for_all feature flag is set to true" do
          before do
            Feature.activate(:seller_refund_policy_disabled_for_all)
          end

          it "saves product refund policy fine print on purchase" do
            purchase, _ = Purchase::CreateService.new(
              product:,
              params:,
              buyer:
            ).perform

            expect(purchase.purchase_refund_policy.title).to eq("30-day money back guarantee")
            expect(purchase.purchase_refund_policy.fine_print).to eq("This is a product-level refund policy")
          end
        end
      end
    end

    context "when the refund policy has no fine print" do
      let!(:refund_policy) do
        create(:product_refund_policy, fine_print: "", product:, seller: user)
      end

      it "saves product refund policy title on purchase" do
        purchase, _ = Purchase::CreateService.new(
          product:,
          params:,
          buyer:
        ).perform

        expect(purchase.purchase_refund_policy.max_refund_period_in_days).to eq(30)
        expect(purchase.purchase_refund_policy.title).to eq("30-day money back guarantee")
        expect(purchase.purchase_refund_policy.fine_print).to eq(nil)
      end

      context "when the account-level refund policy is enabled" do
        before do
          user.refund_policy.update!(max_refund_period_in_days: 0)
          user.update!(refund_policy_enabled: true)
        end

        it "saves the seller-level refund policy" do
          purchase, _ = Purchase::CreateService.new(
            product:,
            params:,
            buyer:
          ).perform

          expect(purchase.purchase_refund_policy.max_refund_period_in_days).to eq(0)
          expect(purchase.purchase_refund_policy.title).to eq("No refunds allowed")
          expect(purchase.purchase_refund_policy.fine_print).to eq(nil)
        end
      end
    end
  end

  context "when the purchase has an upsell" do
    let(:product) { create(:product_with_digital_versions, user:) }
    let(:upsell) { create(:upsell, seller: user, product:) }
    let!(:upsell_variant) { create(:upsell_variant, upsell:, selected_variant: product.alive_variants.first, offered_variant: product.alive_variants.second) }

    before do
      params[:variants] = [product.alive_variants.second.external_id]
      params[:purchase][:perceived_price_cents] = 100
      params[:accepted_offer] = {
        id: upsell.external_id,
        original_product_id: product.external_id,
        original_variant_id: product.alive_variants.first.external_id,
      }
    end

    context "when the upsell is valid" do
      it "creates an upsell purchase record" do
        purchase, error = Purchase::CreateService.new(
          product:,
          params:,
          buyer:
        ).perform

        expect(purchase.upsell_purchase.upsell).to eq(upsell)
        expect(purchase.upsell_purchase.upsell_variant).to eq(upsell_variant)
        expect(purchase.upsell_purchase.selected_product).to eq(product)
        expect(error).to be_nil
      end
    end

    context "when the upsell variant doesn't exist" do
      before do
        params[:accepted_offer][:original_variant_id] = "invalid"
      end

      it "returns an error" do
        _, error = Purchase::CreateService.new(
          product:,
          params:,
          buyer:
        ).perform
        expect(error).to eq("The upsell purchase must have an associated upsell variant.")
      end
    end
  end

  context "when the purchase has a cross-sell" do
    let(:selected_product) { create(:product, user:) }
    let(:product) { create(:product_with_digital_versions, user:) }
    let(:cross_sell) { create(:upsell, seller: user, product:, variant: product.alive_variants.first, selected_products: [selected_product], offer_code: create(:offer_code, user:, products: [product]), cross_sell: true) }

    before do
      params[:purchase][:perceived_price_cents] = 0
      params[:variants] = [product.alive_variants.first.external_id]
      params[:accepted_offer] = {
        id: cross_sell.external_id,
        original_product_id: selected_product.external_id,
      }
      params[:cart_items] = [
        {
          permalink: product.unique_permalink,
          price_cents: 0,
        },
        {
          permalink: selected_product.unique_permalink,
          price_cents: 0,
        }
      ]
    end

    context "when the cross-sell is valid" do
      it "creates an upsell purchase record" do
        purchase, error = Purchase::CreateService.new(
          product:,
          params:,
          buyer:
        ).perform

        expect(purchase.upsell_purchase.upsell).to eq(cross_sell)
        expect(purchase.upsell_purchase.upsell_variant).to eq(nil)
        expect(purchase.upsell_purchase.selected_product).to eq(selected_product)
        expect(purchase.offer_code).to eq(cross_sell.offer_code)
        expect(purchase.purchase_offer_code_discount.offer_code).to eq(cross_sell.offer_code)
        expect(purchase.purchase_offer_code_discount.offer_code_amount).to eq(100)
        expect(purchase.purchase_offer_code_discount.offer_code_is_percent?).to eq(false)
        expect(purchase.purchase_offer_code_discount.pre_discount_minimum_price_cents).to eq(100)
        expect(error).to be_nil
      end
    end

    context "when the selected product isn't in the cart" do
      before do
        params[:cart_items] = [{ permalink: product.unique_permalink, price_cents: 0 }]
      end

      it "returns an error" do
        _, error = Purchase::CreateService.new(
          product:,
          params:,
          buyer:
        ).perform

        expect(error).to eq("The cart does not have any products to which the upsell applies.")
      end

      context "when the cross-sell is a replacement cross-sell" do
        before do
          cross_sell.update!(replace_selected_products: true)
        end

        it "creates an upsell purchase record" do
          purchase, error = Purchase::CreateService.new(
            product:,
            params:,
            buyer:
          ).perform

          expect(purchase.upsell_purchase.upsell).to eq(cross_sell)
          expect(purchase.upsell_purchase.upsell_variant).to eq(nil)
          expect(purchase.upsell_purchase.selected_product).to eq(selected_product)
          expect(purchase.offer_code).to eq(cross_sell.offer_code)
          expect(purchase.purchase_offer_code_discount.offer_code).to eq(cross_sell.offer_code)
          expect(purchase.purchase_offer_code_discount.offer_code_amount).to eq(100)
          expect(purchase.purchase_offer_code_discount.offer_code_is_percent?).to eq(false)
          expect(purchase.purchase_offer_code_discount.pre_discount_minimum_price_cents).to eq(100)
          expect(error).to be_nil
        end
      end
    end

    context "when the purchase already has an offer code" do
      let(:existing_offer_code) { create(:offer_code, user:, products: [product], amount_cents: 200, code: "existing789") }

      before do
        params[:purchase][:offer_code] = existing_offer_code
      end

      it "retains the existing offer code instead of using the upsell offer code" do
        purchase, error = Purchase::CreateService.new(
          product:,
          params:,
          buyer:
        ).perform

        expect(purchase.upsell_purchase.upsell).to eq(cross_sell)
        expect(purchase.upsell_purchase.selected_product).to eq(selected_product)
        expect(purchase.offer_code).to eq(existing_offer_code)
        expect(purchase.purchase_offer_code_discount.offer_code).to eq(existing_offer_code)
        expect(purchase.purchase_offer_code_discount.offer_code_amount).to eq(200)
        expect(error).to be_nil
      end
    end
  end

  describe "bundle purchases" do
    let(:product) { create(:product, :bundle) }

    context "when the bundle's products have not changed" do
      before do
        product.bundle_products.create(product: create(:product, user: product.user), deleted_at: Time.current)
        params[:purchase][:perceived_price_cents] = 100
        params[:bundle_products] = [
          {
            product_id: product.bundle_products.first.product.external_id,
            variant_id: nil,
            quantity: 1,
          },
          {
            product_id: product.bundle_products.second.product.external_id,
            variant_id: nil,
            quantity: 1,
          }
        ]
      end

      it "creates a purchase" do
        purchase, error = Purchase::CreateService.new(
          product:,
          params:,
          buyer:
        ).perform

        expect(error).to be_nil
        expect(purchase.purchase_state).to eq("successful")
        expect(purchase.is_bundle_purchase?).to eq(true)
      end
    end

    context "when the bundle's products have changed" do
      before do
        params[:purchase][:perceived_price_cents] = 100
        params[:bundle_products] = [
          {
            product_id: product.bundle_products.first.product.external_id,
            variant_id: nil,
            quantity: 1,
          }
        ]
      end

      it "returns an error" do
        _, error = Purchase::CreateService.new(
          product:,
          params:,
          buyer:
        ).perform

        expect(error).to eq("The bundle's contents have changed. Please refresh the page!")
      end
    end
  end

  context "when the discount code has a minimum amount" do
    let(:seller) { create(:named_seller) }
    let(:product1) { create(:product, name: "Product 1", user: seller) }
    let(:product2) { create(:product, name: "Product 2", user: seller) }
    let(:product3) { create(:product, name: "Product 3", user: seller) }
    let(:offer_code) { create(:offer_code, user: seller, products: [product1, product3], minimum_amount_cents: 200) }

    context "when the cart items meet the minimum amount" do
      before do
        params[:purchase][:perceived_price_cents] = 0
        params[:cart_items] = [
          {
            permalink: product1.unique_permalink,
            price_cents: 100,
          },
          {
            permalink: product3.unique_permalink,
            price_cents: 100,
          }
        ]
        params[:purchase][:discount_code] = offer_code.code
      end

      it "creates the purchase" do
        purchase, error = Purchase::CreateService.new(
          product: product1,
          params:,
          buyer:
        ).perform

        expect(purchase.offer_code).to eq(offer_code)
        expect(purchase.link).to eq(product1)
        expect(error).to be_nil
      end
    end

    context "when the cart items don't meet the minimum amount" do
      before do
        params[:purchase][:perceived_price_cents] = 0
        params[:cart_items] = [
          {
            permalink: product1.unique_permalink,
            price_cents: 100,
          },
          {
            permalink: product2.unique_permalink,
            price_cents: 100,
          }
        ]
        params[:purchase][:discount_code] = offer_code.code
      end

      it "creates the purchase" do
        _, error = Purchase::CreateService.new(
          product: product1,
          params:,
          buyer:
        ).perform

        expect(error).to eq("Sorry, you have not met the offer code's minimum amount.")
      end
    end
  end

  context "for failed purchase" do
    it "creates a purchase and sets the proper state" do
      params[:purchase][:chargeable] = failed_chargeable

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase.purchase_state).to eq "failed"
      expect(purchase.card_country).to be_present
      expect(purchase.stripe_fingerprint).to be_present
    end

    it "does not enqueue activate integrations worker" do
      params[:purchase][:chargeable] = failed_chargeable

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase.purchase_state).to eq "failed"
      expect(ActivateIntegrationsWorker.jobs.size).to eq(0)
    end

    describe "handling of unexpected errors" do
      context "when a rate limit error occurs" do
        it "does not leave the purchase in in_progress state" do
          expect do
            expect do
              expect do
                expect(Stripe::PaymentIntent).to receive(:create).and_raise(Stripe::RateLimitError)
                Purchase::CreateService.new(product:, params:).perform
              end.to raise_error(ChargeProcessorError)
            end.to change { Purchase.failed.count }.by(1)
          end.not_to change { Purchase.in_progress.count }
        end
      end

      context "when a generic Stripe error occurs" do
        it "does not leave the purchase in in_progress state" do
          expect do
            expect(Stripe::PaymentIntent).to receive(:create).and_raise(Stripe::IdempotencyError)
            purchase, _ = Purchase::CreateService.new(product:, params:).perform
            expect(purchase.purchase_state).to eq("failed")
          end.not_to change { Purchase.in_progress.count }
        end
      end

      context "when a generic Braintree error occurs" do
        it "does not leave the purchase in in_progress state" do
          expect do
            expect(Braintree::Transaction).to receive(:sale).and_raise(Braintree::BraintreeError)
            purchase, _ = Purchase::CreateService.new(product:, params: paypal_params).perform
            expect(purchase.purchase_state).to eq("failed")
          end.not_to change { Purchase.in_progress.count }
        end
      end

      context "when a PayPal connection error occurs" do
        it "does not leave the purchase in in_progress state" do
          create(:merchant_account_paypal, user: product.user, charge_processor_merchant_id: "CJS32DZ7NDN5L", currency: "gbp")

          expect do
            expect_any_instance_of(PayPal::PayPalHttpClient).to receive(:execute).and_raise(PayPalHttp::HttpError.new(418, OpenStruct.new(details: [OpenStruct.new(description: "IO Error")]), nil))
            purchase, _ = Purchase::CreateService.new(product:, params: native_paypal_params).perform
            expect(purchase.purchase_state).to eq("failed")
          end.not_to change { Purchase.in_progress.count }
        end
      end

      context "when unexpected runtime error occurs mid purchase" do
        it "does not leave the purchase in in_progress state" do
          expect do
            expect do
              expect do
                expect_any_instance_of(Purchase).to receive(:charge!).and_raise(RuntimeError)
                Purchase::CreateService.new(product:, params: paypal_params).perform
              end.to raise_error(RuntimeError)
            end.to change { Purchase.failed.count }.by(1)
          end.not_to change { Purchase.in_progress.count }
        end
      end
    end
  end

  it "enqueues activate integrations worker if purchase succeeds" do
    purchase, _ = Purchase::CreateService.new(product:, params:).perform

    expect(purchase.purchase_state).to eq("successful")
    expect(ActivateIntegrationsWorker).to have_enqueued_sidekiq_job(purchase.id)
  end

  it "saves the users locale in json_data" do
    params[:purchase][:locale] = "de"

    purchase, _ = Purchase::CreateService.new(product:, params:).perform

    expect(purchase.locale).to eq "de"
  end

  describe "purchases that require SCA" do
    describe "preorder" do
      let(:product_in_preorder) { create(:product, user:, price_cents: price, is_in_preorder_state: true) }
      let!(:preorder_product) { create(:preorder_link, link: product_in_preorder) }

      before do
        allow_any_instance_of(StripeSetupIntent).to receive(:requires_action?).and_return(true)
      end

      it "creates an in_progress purchase and scheduled a job to check for abandoned SCA later" do
        expect do
          expect do
            purchase, _ = Purchase::CreateService.new(product: product_in_preorder, params: preorder_params).perform

            expect(purchase.purchase_state).to eq "in_progress"
            expect(purchase.preorder.state).to eq "in_progress"
            expect(FailAbandonedPurchaseWorker).to have_enqueued_sidekiq_job(purchase.id)
          end.to change(Purchase, :count).by(1)
        end.to change(Preorder, :count).by(1)
      end
    end

    describe "classic product" do
      before do
        allow_any_instance_of(StripeChargeIntent).to receive(:requires_action?).and_return(true)
      end

      it "creates an in_progress purchase and scheduled a job to check for abandoned SCA later" do
        expect do
          purchase, _ = Purchase::CreateService.new(product:, params:).perform

          expect(purchase.purchase_state).to eq "in_progress"
          expect(FailAbandonedPurchaseWorker).to have_enqueued_sidekiq_job(purchase.id)
        end.to change { Purchase.count }.by 1
      end
    end

    describe "membership" do
      before do
        allow_any_instance_of(StripeChargeIntent).to receive(:requires_action?).and_return(true)
      end

      it "creates an in_progress purchase and renders a proper response" do
        expect do
          expect do
            purchase, _ = Purchase::CreateService.new(product: subscription_product, params: subscription_params).perform

            expect(purchase.purchase_state).to eq "in_progress"
            expect(FailAbandonedPurchaseWorker).to have_enqueued_sidekiq_job(purchase.id)
          end.to change(Purchase.in_progress, :count).by(1)
        end.not_to change(Subscription, :count)
      end
    end
  end

  describe "perceived_price_cents" do
    context "when present" do
      it "sets the purchase's perceived_price_cents" do
        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.perceived_price_cents).to eq 600
      end
    end

    context "when absent" do
      it "sets the purchase's perceived_price_cents to nil" do
        params[:purchase][:perceived_price_cents] = nil

        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.perceived_price_cents).to be_nil
      end
    end
  end

  describe "is_mobile" do
    it "sets is_mobile to `false` if not mobile" do
      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase.is_mobile).to be false
    end

    it "sets is_mobile to `true` if is mobile" do
      params[:purchase][:is_mobile] = true

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase.is_mobile).to be true
    end
  end

  describe "multi_buy" do
    it "sets is_multi_buy field to true if purchase is part of multi-buy" do
      params[:purchase][:is_multi_buy] = "true"

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase.is_multi_buy).to be true
    end

    it "sets is_multi_buy field to false if purchase is not part of multi-buy" do
      params[:purchase][:is_multi_buy] = nil

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase.is_multi_buy).to be false
    end
  end

  describe "expiry fields" do
    it "allows a bad expiry_date" do
      _, error = Purchase::CreateService.new(
        product:,
        params: params.merge(expiry_date: "01/01/2011")
      ).perform

      expect(error).to be_nil
    end

    it "accepts 4 digit expiry year and does not prepend it with 20" do
      params[:expiry_date] = "12/2023"

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase.purchase_state).to eq "successful"
      expect(purchase.card_expiry_month).to eq 12
      expect(purchase.card_expiry_year).to eq 2023
    end

    context "with expiry date field instead of month and year" do
      it "accepts expiry date in one field" do
        params[:expiry_month] = params[:expiry_year] = ""
        params[:expiry_date] = "12/23"

        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.purchase_state).to eq "successful"
        expect(purchase.card_expiry_month).to eq 12
        expect(purchase.card_expiry_year).to eq 2023
      end

      it "accepts 5 digit expiry date field with spaces and dash" do
        params[:expiry_month] = params[:expiry_year] = ""
        params[:expiry_date] = "12 - 23"

        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.purchase_state).to eq "successful"
        expect(purchase.card_expiry_month).to eq 12
        expect(purchase.card_expiry_year).to eq 2023
      end
    end
  end

  context "when the user has a different currency" do
    describe "english pound" do
      it "sets the displayed price on the purchase" do
        product.update!(price_currency_type: :gbp, price_cents: 600)
        product.reload

        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.displayed_price_cents).to eq price
        expect(purchase.displayed_price_currency_type).to eq :gbp

        expect(purchase.price_cents).to eq 919
        expect(purchase.total_transaction_cents).to eq 919
        expect(purchase.rate_converted_to_usd).to eq "0.652571"
      end
    end

    describe "yen" do
      before :each do
        product.update!(price_currency_type: :jpy, price_cents: 100)
        product.reload
      end

      it "sets the displayed price on the purchase" do
        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.price_cents).to eq 128 # in usd
        expect(purchase.total_transaction_cents).to eq 128 # in usd
        expect(purchase.displayed_price_cents).to eq 100 # in jpy
      end

      it "properly increments users balance" do
        params[:purchase][:perceived_price_cents] = 100

        Purchase::CreateService.new(
          product:,
          params:
        ).perform

        expect(user.unpaid_balance_cents).to eq 31 # 128c (price) - 13c (10% flat fee) - 50c - 4c (2.9% cc fee) - 30c (fixed cc fee)
      end
    end
  end

  describe "purchase emails" do
    it "sends the correct purchase emails" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(ContactingCreatorMailer).to receive(:notify).and_return(mail_double)

      Purchase::CreateService.new(product:, params:).perform
      expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(Purchase.last.id).on("critical")
    end

    it "sends the correct purchase emails for zero plus links" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(ContactingCreatorMailer).to receive(:notify).and_return(mail_double)

      product.update!(price_range: "0+")
      params[:purchase].merge!(perceived_price_cents: 0, price_range: "0")

      Purchase::CreateService.new(product:, params:).perform
      expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(Purchase.last.id).on("critical")
    end

    it "does not send the purchase emails to creator for free downloads if notifications are disabled" do
      expect(ContactingCreatorMailer).to_not receive(:mail)

      user.update!(enable_free_downloads_email: true)
      product.update!(price_range: "0")
      params[:purchase].merge!(perceived_price_cents: 0, price_range: "0")

      Sidekiq::Testing.inline! do
        Purchase::CreateService.new(product:, params:).perform
      end
    end

    it "does not send the purchase notification to creator for free downloads if notifications are disabled" do
      user.update!(enable_free_downloads_push_notification: true)
      product.update!(price_range: "0")
      params[:purchase].merge!(perceived_price_cents: 0, price_range: "0")

      Sidekiq::Testing.inline! do
        Purchase::CreateService.new(product:, params:).perform
      end

      expect(PushNotificationWorker.jobs.size).to eq(0)
    end

    it "does not send the owner an email update if they've turned off payment notifications" do
      user.update_attribute(:enable_payment_email, false)
      expect(ContactingCreatorMailer).to_not receive(:mail)

      Sidekiq::Testing.inline! do
        Purchase::CreateService.new(product:, params:).perform
      end
    end

    it "does not send the creator a push notification if they've turned off payment notifications" do
      user.update!(enable_payment_push_notification: true)

      Sidekiq::Testing.inline! do
        Purchase::CreateService.new(product:, params:).perform
      end

      expect(PushNotificationWorker.jobs.size).to eq(0)
    end
  end

  context "with quantity greater than 1" do
    let(:quantity_params) do
      params[:purchase].merge!(quantity: 4)
      params
    end

    it "creates a purchase with quantity set" do
      expect do
        purchase, _ = Purchase::CreateService.new(product:, params: quantity_params).perform

        expect(purchase.quantity).to eq 4
      end.to change { Purchase.count }.by(1)
    end

    context "and greater than what is available for the product" do
      it "returns an error" do
        product.update!(max_purchase_count: 3)

        purchase, error = Purchase::CreateService.new(product:, params: quantity_params).perform

        expect(purchase.failed?).to be true
        expect(purchase.error_code).to eq "exceeding_product_quantity"
        expect(error).to eq "You have chosen a quantity that exceeds what is available."
      end
    end
  end

  context "with url redirect" do
    it "creates a UrlRedirect object" do
      expect do
        Purchase::CreateService.new(product:, params:).perform
      end.to change { UrlRedirect.count }.by(1)
    end
  end

  context "with url_parameters" do
    it "parses 'url_parameters' containing single quotes correctly and allows purchase" do
      params[:purchase][:url_parameters] = "{'source_url':'https%3A%2F%2Fwww.afrodjmac.com%2Fblog%2F2013%2F01%2F10%2Ffender-rhodes-ableton-live-pack'}"

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase.url_parameters["source_url"]).to eq "https%3A%2F%2Fwww.afrodjmac.com%2Fblog%2F2013%2F01%2F10%2Ffender-rhodes-ableton-live-pack"
      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(Purchase.last.id, JSON.parse(params[:purchase][:url_parameters]))
    end

    it "parses 'url_parameters' not containing single quotes correctly and allows purchase" do
      params[:purchase][:url_parameters] = "{\"source_url\":\"https%3A%2F%2Fwww.afrodjmac.com%2Fblog%2F2013%2F01%2F10%2Ffender-rhodes-ableton-live-pack\"}"

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase.url_parameters["source_url"]).to eq "https%3A%2F%2Fwww.afrodjmac.com%2Fblog%2F2013%2F01%2F10%2Ffender-rhodes-ableton-live-pack"
      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(Purchase.last.id, JSON.parse(params[:purchase][:url_parameters]))
    end

    it "allows purchase even when 'url_parameters' contains an invalid json string" do
      params[:purchase][:url_parameters] = "{{"

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase.url_parameters).to be_nil
      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(Purchase.last.id, nil)
    end
  end

  context "with wallet_type parameter" do
    it "creates a PurchaseWalletType when valid params" do
      expect do
        Purchase::CreateService.new(product:, params: params.merge(wallet_type: "apple_pay")).perform
      end.to change { PurchaseWalletType.count }.by(1)
      .and change { Purchase.count }.by(1)
      expect(PurchaseWalletType.last.wallet_type).to eq("apple_pay")
    end

    it "creates a PurchaseWalletType when valid params despite invalid record" do
      PurchaseWalletType.create(purchase_id: 0, wallet_type: "apple_pay")
      expect do
        Purchase::CreateService.new(product:, params: params.merge(wallet_type: "apple_pay")).perform
      end.to change { PurchaseWalletType.count }.by(1)
      .and change { Purchase.count }.by(1)
      expect(PurchaseWalletType.last.wallet_type).to eq("apple_pay")
    end

    it "does not create a PurchaseWalletType when invalid params" do
      variant_for_other_product = create(:variant, name: "Small")
      params[:variants] = [variant_for_other_product.external_id]
      params.merge!(wallet_type: "apple_pay")
      expect do
        Purchase::CreateService.new(product:, params:).perform
      end.to change { PurchaseWalletType.count }.by(0)
      .and change { Purchase.count }.by(0)
    end
  end

  context "when sales tax is not applicable" do
    let(:product) { create(:product, user:, price_cents: price) }
    let(:sales_tax_params) do
      base_params[:purchase].merge!(
        full_name: "Edgar Gumstein",
        street_address: "123 Gum Road",
        country: "US",
        state: "CA",
        city: "San Francisco",
        zip_code: "94104"
      )
      base_params
    end

    context "and zip code validation is used" do
      it "creates a purchase for a valid 5-digit zip code" do
        expect do
          Purchase::CreateService.new(product:, params: sales_tax_params).perform
        end.to change { Purchase.count }.by(1)

        expect(Purchase.last.zip_code).to eq("94104")
      end

      it "creates a purchase for a valid 5-digit zip code in Puerto Rico" do
        expect do
          Purchase::CreateService.new(product:, params: sales_tax_params.deep_merge(purchase: { zip_code: "00735" })).perform
        end.to change { Purchase.count }.by(1)

        expect(Purchase.last.zip_code).to eq("00735")
      end

      it "creates a purchase for a valid zip+4 code" do
        expect do
          Purchase::CreateService.new(product:, params: sales_tax_params.deep_merge(purchase: { zip_code: "94104-5401" })).perform
        end.to change { Purchase.count }.by(1)

        expect(Purchase.last.zip_code).to eq("94104-5401")
      end

      it "returns an error for an non-existent 5-digit zip code" do
        expect do
          _, error = Purchase::CreateService.new(product:, params: sales_tax_params.deep_merge(purchase: { zip_code: "11111" })).perform
          expect(error).to eq "You entered a ZIP Code that doesn't exist within your country."
        end.to change { Purchase.count }.by(0)
      end

      it "returns an error for a zip code that is less than 5 digits" do
        expect do
          _, error = Purchase::CreateService.new(product:, params: sales_tax_params.deep_merge(purchase: { zip_code: "9410" })).perform
          expect(error).to eq "You entered a ZIP Code that doesn't exist within your country."
        end.to change { Purchase.count }.by(0)
      end

      it "returns an error for a zip code that is more than 5 digits but not a zip+4" do
        expect do
          _, error = Purchase::CreateService.new(product:, params: sales_tax_params.deep_merge(purchase: { zip_code: "94104-540" })).perform
          expect(error).to eq "You entered a ZIP Code that doesn't exist within your country."
        end.to change { Purchase.count }.by(0)
      end
    end
  end

  context "when sales tax is applicable" do
    let(:product) { create(:physical_product, user:, price_cents: price) }
    let(:sales_tax_params) do
      base_params[:purchase].merge!(
        full_name: "Edgar Gumstein",
        street_address: "123 Gum Road",
        country: "US",
        state: "CA",
        city: "San Francisco",
        zip_code: "94117"
      )
      base_params
    end

    context "and zip code validation is used" do
      context "with an invalid zip code" do
        it "returns an error if the product is tax eligible and shipped to anywhere in the US" do
          sales_tax_params[:purchase].merge!(zip_code: "invalidzip")
          _, error = Purchase::CreateService.new(product:, params: sales_tax_params).perform

          expect(error).to eq "You entered a ZIP Code that doesn't exist within your country."
        end
      end
    end

    context "for a foreign sale" do
      it "creates a purchase_sales_tax_info entry for the purchase" do
        product.shipping_destinations << ShippingDestination.new(country_code: "US", one_item_rate_cents: 0, multiple_items_rate_cents: 0)

        sales_tax_params[:purchase].merge!(
          sales_tax_country_code_election: "IT",
          ip_address: "2.47.255.255", # Italy
          ip_country: "Italy"
        )

        purchase, _ = Purchase::CreateService.new(product:, params: sales_tax_params).perform

        actual_purchase_sales_tax_info = purchase.purchase_sales_tax_info
        expect(actual_purchase_sales_tax_info).not_to be_nil
        expect(actual_purchase_sales_tax_info.elected_country_code).to eq "IT"
        expect(actual_purchase_sales_tax_info.card_country_code).to be_nil
        expect(actual_purchase_sales_tax_info.postal_code).to eq "94117"
        expect(actual_purchase_sales_tax_info.ip_country_code).to eq "IT"
        expect(actual_purchase_sales_tax_info.country_code).to eq Compliance::Countries::USA.alpha2
        expect(actual_purchase_sales_tax_info.ip_address).to eq "2.47.255.255"
      end
    end

    context "when VAT ID is provided" do
      it "creates a purchase_sales_tax_info record with the provided VAT ID" do
        sales_tax_params[:purchase][:business_vat_id] = "IE6388047V"

        purchase, _ = Purchase::CreateService.new(product:, params: sales_tax_params).perform

        actual_purchase_sales_tax_info = purchase.purchase_sales_tax_info
        expect(actual_purchase_sales_tax_info).to_not be_nil
        expect(actual_purchase_sales_tax_info.business_vat_id).to eq "IE6388047V"
      end

      context "but is invalid" do
        it "creates a purchase_sales_tax_info record without a VAT ID" do
          sales_tax_params[:purchase][:business_vat_id] = "DE123"

          purchase, _ = Purchase::CreateService.new(product:, params: sales_tax_params).perform

          actual_purchase_sales_tax_info = purchase.purchase_sales_tax_info
          expect(actual_purchase_sales_tax_info).to_not be_nil
          expect(actual_purchase_sales_tax_info.business_vat_id).to be_nil
        end
      end
    end
  end

  context "for a preorder purchase" do
    let(:product_in_preorder) { create(:product, user:, price_cents: price, is_in_preorder_state: true) }
    let!(:preorder_product) { create(:preorder_link, link: product_in_preorder) }

    it "creates the preorder and its auth charge, with successful states" do
      purchase, _ = Purchase::CreateService.new(
        product: product_in_preorder,
        params: preorder_params,
      ).perform

      preorder = Preorder.last

      expect(preorder.state).to eq "authorization_successful"
      expect(preorder.authorization_purchase).to eq purchase
      expect(preorder.authorization_purchase.credit_card).to be_present
      expect(purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(purchase.url_redirect).not_to be_present
      expect(product_in_preorder.user.balances).to be_empty
    end

    it "creates the preorder and its auth charge, with successful states for paypal chargeable" do
      purchase, _ = Purchase::CreateService.new(
        product: product_in_preorder,
        params: paypal_preorder_params,
      ).perform

      preorder = Preorder.last

      expect(preorder.state).to eq "authorization_successful"
      expect(preorder.authorization_purchase).to eq purchase
      expect(preorder.authorization_purchase.credit_card).to be_present
      expect(purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(purchase.url_redirect).not_to be_present
      expect(product_in_preorder.user.balances).to be_empty
    end

    it "creates a successful multi-quantity preorder" do
      preorder_params[:purchase][:perceived_price_cents] = price * 3
      preorder_params[:purchase][:quantity] = 3

      purchase, _ = Purchase::CreateService.new(
        product: product_in_preorder,
        params: preorder_params
      ).perform

      preorder = Preorder.last

      expect(preorder.state).to eq "authorization_successful"
      expect(preorder.authorization_purchase).to eq purchase
      expect(preorder.authorization_purchase.credit_card).to be_present
      expect(purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(purchase.quantity).to eq 3
      expect(purchase.url_redirect).not_to be_present
      expect(product_in_preorder.user.balances).to be_empty
    end

    it "sends the correct preorder emails" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(ContactingCreatorMailer).to receive(:notify).and_return(mail_double)
      expect(CustomerMailer).to receive(:preorder_receipt).and_return(mail_double)

      Purchase::CreateService.new(
        product: product_in_preorder,
        params: preorder_params,
      ).perform
    end

    it "counts a successful preorder towards the product's max purchase count" do
      product_in_preorder.update(max_purchase_count: 1)

      purchase, _ = Purchase::CreateService.new(
        product: product_in_preorder,
        params: preorder_params
      ).perform

      preorder = Preorder.last

      expect(preorder.state).to eq "authorization_successful"
      expect(purchase.purchase_state).to eq "preorder_authorization_successful"

      preorder_params[:purchase][:email] = "gumgum@gumroad.gum"
      Purchase::CreateService.new(
        product: product_in_preorder,
        params: preorder_params
      ).perform

      preorder = Preorder.last
      expect(preorder.state).to eq "authorization_failed"
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_failed"
    end

    it "counts a successful preorder towards the variant's max purchase count" do
      category = create(:variant_category, title: "sizes", link: product_in_preorder)
      variant = create(:variant, name: "small", max_purchase_count: 1, variant_category: category)
      preorder_params[:variants] = [variant.external_id]

      purchase, _ = Purchase::CreateService.new(
        product: product_in_preorder,
        params: preorder_params
      ).perform

      preorder = Preorder.last
      expect(preorder.state).to eq "authorization_successful"
      expect(purchase.purchase_state).to eq "preorder_authorization_successful"

      preorder_params[:purchase][:email] = "gumgum@gumroad.gum"
      Purchase::CreateService.new(
        product: product_in_preorder,
        params: preorder_params
      ).perform

      preorder = Preorder.last
      expect(preorder.state).to eq "authorization_failed"
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_failed"
    end

    it "counts a successful preorder towards the offer code's max purchase count" do
      offer_code = create(:offer_code, products: [product_in_preorder], amount_cents: 200, max_purchase_count: 1)
      preorder_params[:purchase][:discount_code] = offer_code.code
      preorder_params[:purchase][:perceived_price_cents] = 400

      purchase, _ = Purchase::CreateService.new(
        product: product_in_preorder,
        params: preorder_params
      ).perform

      preorder = Preorder.last

      expect(preorder.state).to eq "authorization_successful"
      expect(purchase.purchase_state).to eq "preorder_authorization_successful"

      travel_to(1.day.from_now) do
        preorder_params[:purchase][:email] = "gumgum@gumroad.gum"

        Purchase::CreateService.new(
          product: product_in_preorder,
          params: preorder_params
        ).perform

        preorder = Preorder.last

        expect(preorder.state).to eq "authorization_failed"
        expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_failed"
        expect(preorder.authorization_purchase.error_code).to eq "offer_code_sold_out"
      end
    end

    it "allows the normal purchase of the product once it's released" do
      product_in_preorder.update(is_in_preorder_state: false)
      preorder_params[:purchase].delete(:is_preorder_authorization)

      expect do
        purchase, _ = Purchase::CreateService.new(
          product: product_in_preorder,
          params: preorder_params
        ).perform

        expect(purchase.purchase_state).to eq "successful"
        expect(product_in_preorder.user.unpaid_balance_cents).to eq 443 # 600c (price) - 60c (10 % flat fee) - 50c - 17c (2.9% cc fee) - 30c (fixed cc fee)
      end.not_to change { Preorder.count }
    end

    it "disallows 2 preorder auth charges in a row" do
      purchase, _ = Purchase::CreateService.new(
        product: product_in_preorder,
        params: preorder_params
      ).perform

      expect(purchase.purchase_state).to eq "preorder_authorization_successful"

      _, error = Purchase::CreateService.new(
        product: product_in_preorder,
        params: preorder_params
      ).perform

      expect(error).to eq "You have already pre-ordered this product. A confirmation has been emailed to you."
    end

    it "does not allow the product to be purchased if it's in preorder state" do
      preorder_params[:purchase][:is_preorder_authorization] = false

      _, error = Purchase::CreateService.new(
        product: product_in_preorder,
        params: preorder_params
      ).perform

      expect(error).to eq "Something went wrong. Please refresh the page to pre-order the product."
    end

    it "does not allow the product to be preordered if it's released" do
      product_in_preorder.update(is_in_preorder_state: false)

      _, error = Purchase::CreateService.new(
        product: product_in_preorder,
        params: preorder_params
      ).perform

      expect(error).to eq "The product was just released. Refresh the page to purchase it."
    end

    describe "shipping details" do
      let(:shipping_params) do
        preorder_params[:purchase].merge!(
          full_name: "Edgar Gumstein",
          street_address: "123 Gum Road",
          country: "US",
          state: "CA",
          city: "San Francisco",
          zip_code: "94117"
        )
        preorder_params
      end

      it "does not save the country if the product is not physical or shipping required" do
        purchase, _ = Purchase::CreateService.new(
          product: product_in_preorder,
          params: shipping_params
        ).perform

        expect(purchase.country).to be_nil
      end

      it "saves the country if the product is physical or shipping required" do
        product_in_preorder.update!(require_shipping: true)

        purchase, _ = Purchase::CreateService.new(
          product: product_in_preorder,
          params: shipping_params
        ).perform

        expect(purchase.country).to eq("United States")

        product_in_preorder.update!(is_physical: true)
        product_in_preorder.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 0, multiple_items_rate_cents: 0)

        purchase, _ = Purchase::CreateService.new(
          product: product_in_preorder,
          params: shipping_params
        ).perform

        expect(purchase.country).to eq("United States")
      end
    end

    describe "test purchases" do
      it "allows the buyer to test-purchase a preorder" do
        expect do
          expect do
            purchase, _ = Purchase::CreateService.new(
              product: product_in_preorder,
              params: preorder_params,
              buyer: user
            ).perform

            expect(purchase.purchase_state).to eq "test_preorder_successful"
            expect(Preorder.last.state).to eq("test_authorization_successful")
          end.to_not change { UrlRedirect.count }
        end.to_not change { user.unpaid_balance_cents }
      end
    end

    describe "affiliate notification" do
      context "digital product" do
        it "notifies the affiliate" do
          direct_affiliate = create(:direct_affiliate, seller: product.user)
          params[:purchase][:affiliate_id] = direct_affiliate.id

          mail_double = double
          allow(mail_double).to receive(:deliver_later)
          expect(AffiliateMailer).to receive(:notify_affiliate_of_sale).and_return(mail_double)

          Purchase::CreateService.new(product:, params:).perform
        end
      end

      context "membership product" do
        let(:product) { create(:membership_product, price_cents: price) }
        let(:direct_affiliate) { create(:direct_affiliate, seller: product.user) }
        let(:tiered_membership_params) do
          subscription_params[:purchase][:is_original_subscription_purchase] = true
          subscription_params[:price_id] = product.default_price.external_id
          subscription_params[:variants] = [product.tiers.first.external_id]
          subscription_params[:purchase][:affiliate_id] = direct_affiliate.id
          subscription_params
        end

        it "notifies the affiliate" do
          mail_double = double
          allow(mail_double).to receive(:deliver_later)
          expect(AffiliateMailer).to receive(:notify_affiliate_of_sale).and_return(mail_double)

          Purchase::CreateService.new(product:, params: tiered_membership_params).perform
        end

        context "with free trial enabled" do
          it "notifies the affiliate" do
            product.update!(free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week)
            tiered_membership_params[:purchase][:is_free_trial_purchase] = true
            tiered_membership_params[:perceived_free_trial_duration] = { amount: product.free_trial_duration_amount, unit: product.free_trial_duration_unit }

            mail_double = double
            allow(mail_double).to receive(:deliver_later)
            expect(AffiliateMailer).to receive(:notify_affiliate_of_sale).and_return(mail_double)

            Purchase::CreateService.new(product:, params: tiered_membership_params).perform
          end
        end
      end
    end

    context "for a product with a collaborator" do
      it "sets the collaborator as the purchase affiliate" do
        collaborator = create(:collaborator, affiliate_basis_points: 40_00)
        create(:product_affiliate, affiliate: collaborator, product:, affiliate_basis_points: 50_00)
        params[:purchase][:affiliate_id] = create(:user).global_affiliate.id # overrides affiliate passed in params

        purchase, error = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.affiliate).to eq collaborator
        expect(purchase.affiliate_credit_cents).to eq 2_21
        expect(purchase.affiliate_credit.fee_cents).to eq 79
        expect(error).to be_nil
      end
    end

    context "with invalid params" do
      it "creates the preorder and its auth charge with failed states if bad card number" do
        preorder_params[:purchase][:chargeable] = CardParamsHelper.build_chargeable(
          StripePaymentMethodHelper.decline_invalid_luhn.to_stripejs_params,
          browser_guid
        )

        purchase, _ = Purchase::CreateService.new(
          product: product_in_preorder,
          params: preorder_params,
        ).perform

        preorder = Preorder.last

        expect(preorder.state).to eq "authorization_failed"
        expect(preorder.authorization_purchase).to eq purchase
        expect(purchase.purchase_state).to eq "preorder_authorization_failed"
      end

      it "creates the preorder and its auth charge with failed states if bad cvc" do
        preorder_params[:purchase][:chargeable] = CardParamsHelper.build_chargeable(
          StripePaymentMethodHelper.decline_cvc_check_fails.to_stripejs_params,
          browser_guid
        )

        purchase, _ = Purchase::CreateService.new(
          product: product_in_preorder,
          params: preorder_params,
        ).perform

        preorder = Preorder.last

        expect(preorder.state).to eq "authorization_failed"
        expect(preorder.authorization_purchase).to eq purchase
        expect(purchase.purchase_state).to eq "preorder_authorization_failed"
      end

      it "creates the preorder and its auth charge with failed states if declining card" do
        preorder_params[:purchase][:chargeable] = CardParamsHelper.build_chargeable(
          StripePaymentMethodHelper.decline.to_stripejs_params,
          browser_guid
        )

        purchase, _ = Purchase::CreateService.new(
          product: product_in_preorder,
          params: preorder_params,
        ).perform

        preorder = Preorder.last

        expect(preorder.state).to eq "authorization_failed"
        expect(preorder.authorization_purchase).to eq purchase
        expect(purchase.purchase_state).to eq "preorder_authorization_failed"
      end
    end
  end

  context "for a product that requires shipping" do
    it "creates a shipment" do
      product = create(:physical_product)

      expect do
        Purchase::CreateService.new(product:, params:).perform
      end.to change { Shipment.count }.by(1)
    end

    describe "failures" do
      let(:product) { create(:physical_product, price_cents: price, user:) }

      it "returns an error message if country is not in compliance" do
        _, error = Purchase::CreateService.new(product:, params: shipping_params).perform

        expect(error).to eq "The creator cannot ship the product to the country you have selected."
      end

      it "returns an error message and fails purchase if the seller cannot ship to the country" do
        product.shipping_destinations.destroy_all
        product.shipping_destinations << ShippingDestination.new(
          country_code: "CA",
          one_item_rate_cents: 10_00,
          multiple_items_rate_cents: 5_00
        )
        shipping_params[:purchase][:country] = "US"

        purchase, error = Purchase::CreateService.new(product:, params: shipping_params).perform

        expect(purchase.failed?).to be true
        expect(error).to eq "The creator cannot ship the product to the country you have selected."
      end
    end
  end

  context "for a product with variants" do
    it "associates the selected variants" do
      product = create(:product)
      size = create(:variant_category, link: product, title: "Size")
      small = create(:variant, variant_category: size, name: "Small")

      params[:variants] = [small.external_id]

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase.variant_attributes).to match_array [small]
    end
  end

  context "for a product with SKUs" do
    it "associates the default SKU if no variants provided" do
      product = create(:physical_product)
      default_sku = product.skus.is_default_sku.first

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase.variant_attributes).to match_array [default_sku]
    end
  end

  context "for a subscription or tiered membership product" do
    let(:product) { create(:membership_product, price_cents: price) }
    let(:tier) { product.tiers.first }
    let(:second_tier) { create(:variant, variant_category: product.tier_category) }
    let(:tiered_membership_params) do
      subscription_params[:purchase][:is_original_subscription_purchase] = true
      subscription_params[:price_id] = product.default_price.external_id
      subscription_params[:variants] = [tier.external_id]
      subscription_params
    end

    it "creates a new purchase" do
      expect do
        Purchase::CreateService.new(
          product:,
          params: tiered_membership_params
        ).perform
      end.to change { product.sales.count }.by(1)

      purchase = product.sales.last
      expect(purchase.is_original_subscription_purchase).to be(true)
    end

    it "creates a new subscription" do
      expect do
        Purchase::CreateService.new(
          product:,
          params: tiered_membership_params
        ).perform
      end.to change { product.subscriptions.count }.by(1)

      subscription = product.subscriptions.last
      expect(subscription.link).to eq product
      expect(subscription.cancelled_at).to be(nil)
      expect(subscription.failed_at).to be(nil)
      expect(subscription.payment_options.count).to eq 1
      payment_option = subscription.payment_options.last
      expect(payment_option.price).to eq product.prices.alive.is_buy.last
    end

    it "does not allow a purchase through with a quantity greater than what is available for the tier" do
      tier.update!(max_purchase_count: 1)

      active_subscription = create(:subscription, link: product)
      create(:purchase, link: product, variant_attributes: [tier], subscription: active_subscription, is_original_subscription_purchase: true)

      purchase, error = Purchase::CreateService.new(
        product:,
        params: tiered_membership_params,
      ).perform

      expect(purchase.failed?).to be true
      expect(error).to eq "Sold out, please go back and pick another option."
    end

    context "when selecting a specific price" do
      before :each do
        tier.save_recurring_prices!({
                                      BasePrice::Recurrence::YEARLY => {
                                        enabled: true,
                                        price: "100"
                                      },
                                      BasePrice::Recurrence::MONTHLY => {
                                        enabled: true,
                                        price: "10"
                                      }
                                    })
        second_tier.save_recurring_prices!(
          BasePrice::Recurrence::YEARLY => {
            enabled: true,
            price: "120"
          },
          BasePrice::Recurrence::MONTHLY => {
            enabled: true,
            price: "12"
          }
        )
        @yearly_price = product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::YEARLY)
        tiered_membership_params[:price_id] = @yearly_price.external_id
      end

      it "sets the purchase's price correctly given the product price_id provided" do
        purchase, _ = Purchase::CreateService.new(
          product:,
          params: tiered_membership_params
        ).perform

        expect(purchase.purchase_state).to eq "successful"
        expect(purchase.displayed_price_cents).to eq 100_00
      end

      it "associates the price with the subscription payment option" do
        purchase, _ = Purchase::CreateService.new(
          product:,
          params: tiered_membership_params
        ).perform

        payment_option = purchase.subscription.last_payment_option

        expect(payment_option).to be
        expect(payment_option.price).to eq @yearly_price
      end

      context "for a tier with pay-what-you-want pricing" do
        before :each do
          tier.save_recurring_prices!({
                                        BasePrice::Recurrence::YEARLY => {
                                          enabled: true,
                                          price: "100",
                                          suggested_price: "120"
                                        },
                                        BasePrice::Recurrence::MONTHLY => {
                                          enabled: true,
                                          price: "10",
                                          suggested_price: "12"
                                        }
                                      })
          tier.update!(customizable_price: true)
          tiered_membership_params[:purchase][:perceived_price_cents] = 110_00
        end

        it "sets the purchase's price correctly given perceived_price_cents" do
          purchase, _ = Purchase::CreateService.new(
            product:,
            params: tiered_membership_params
          ).perform

          expect(purchase.purchase_state).to eq "successful"
          expect(purchase.displayed_price_cents).to eq 110_00
        end

        it "still associates the right price with the subscription payment option" do
          purchase, _ = Purchase::CreateService.new(
            product:,
            params: tiered_membership_params
          ).perform

          payment_option = purchase.subscription.last_payment_option

          expect(payment_option).to be
          expect(payment_option.price).to eq @yearly_price
        end

        context "missing perceived_price_cents" do
          it "uses the price_cents of the associated price_id" do
            tiered_membership_params[:purchase].delete(:perceived_price_cents)

            purchase, _ = Purchase::CreateService.new(
              product:,
              params: tiered_membership_params
            ).perform

            expect(purchase.displayed_price_cents).to eq 100_00
          end
        end

        context "with a price that is too low" do
          it "returns an error" do
            tiered_membership_params[:purchase][:perceived_price_cents] = 90_00

            purchase, error = Purchase::CreateService.new(
              product:,
              params: tiered_membership_params
            ).perform

            expect(purchase.purchase_state).to eq "failed"
            expect(error).to eq "Please enter an amount greater than or equal to the minimum."
          end
        end
      end

      context "with an invalid price_id" do
        it "assigns the product's default price to the purchase" do
          default_price = product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::MONTHLY)

          tiered_membership_params[:variants] = [second_tier.external_id]
          tiered_membership_params[:price_id] = "invalid-id"

          purchase, _ = Purchase::CreateService.new(
            product:,
            params: tiered_membership_params
          ).perform

          expect(purchase.purchase_state).to eq "successful"
          expect(purchase.displayed_price_cents).to eq 12_00
          expect(purchase.subscription.last_payment_option.price).to eq default_price
        end
      end

      context "when the variant is missing a price for that recurrence" do
        it "treats the product as free" do
          tier.prices.destroy_all
          tier.update!(price_difference_cents: 5_00)

          purchase, _ = Purchase::CreateService.new(
            product:,
            params: tiered_membership_params
          ).perform

          expect(purchase.displayed_price_cents).to eq 0
        end
      end

      context "with an invalid tier ID" do
        it "returns an error" do
          tiered_membership_params[:variants] = ["invalid-id"]

          _, error = Purchase::CreateService.new(
            product:,
            params: tiered_membership_params
          ).perform

          expect(error).to eq "The product's variants have changed, please refresh the page!"
        end
      end
    end

    context "when the product has a free trial enabled" do
      let(:free_trial_membership_params) do
        tiered_membership_params[:purchase][:is_free_trial_purchase] = true
        tiered_membership_params[:perceived_free_trial_duration] = {
          unit: product.free_trial_duration_unit,
          amount: product.free_trial_duration_amount,
        }
        tiered_membership_params
      end

      before do
        product.update!(free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week)
      end

      it "creates a not_charged purchase but does not charge the user immediately" do
        expect(Stripe::PaymentIntent).not_to receive(:create)

        purchase, _ = Purchase::CreateService.new(
          product:,
          params: free_trial_membership_params
        ).perform

        expect(purchase.purchase_state).to eq "not_charged"
        expect(purchase.stripe_transaction_id).to be_nil
        expect(purchase.displayed_price_cents).to eq 600
      end

      it "creates a setup_intent for the purchase" do
        purchase, _ = Purchase::CreateService.new(
          product:,
          params: free_trial_membership_params
        ).perform

        expect(purchase.processor_setup_intent_id).to be_present
      end

      it "creates a subscription" do
        purchase, _ = Purchase::CreateService.new(
          product:,
          params: free_trial_membership_params
        ).perform

        expect(purchase.subscription_id).to be_present
        expect(purchase.subscription.recurrence).to eq "monthly"
        expect(purchase.subscription.free_trial_ends_at.to_date).to eq 1.week.from_now.to_date
      end

      it "creates a credit card" do
        purchase, _ = Purchase::CreateService.new(
          product:,
          params: free_trial_membership_params
        ).perform

        expect(purchase.credit_card_id).to be_present
        expect(purchase.subscription.credit_card_id).to be_present
      end

      it "queues a job to charge the subscriber at the end of the free trial" do
        freeze_time do
          purchase, _ = Purchase::CreateService.new(
            product:,
            params: free_trial_membership_params
          ).perform

          expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(purchase.subscription_id).in(1.week)
        end
      end

      it "queues a job to remind the subscriber their trial is expiring" do
        freeze_time do
          purchase, _ = Purchase::CreateService.new(
            product:,
            params: free_trial_membership_params
          ).perform

          expect(FreeTrialExpiringReminderWorker).to have_enqueued_sidekiq_job(purchase.subscription.id).at(5.days.from_now)
        end
      end

      context "missing or incorrect perceived free trial duration" do
        it "returns an error if missing perceived free trial duration" do
          free_trial_membership_params.delete(:perceived_free_trial_duration)

          _, error = Purchase::CreateService.new(
            product:,
            params: free_trial_membership_params
          ).perform

          expect(error).to eq "Invalid free trial information provided. Please try again."
        end

        it "returns an error if missing perceived free trial duration amount" do
          free_trial_membership_params[:perceived_free_trial_duration].delete(:amount)

          _, error = Purchase::CreateService.new(
            product:,
            params: free_trial_membership_params
          ).perform

          expect(error).to eq "Invalid free trial information provided. Please try again."
        end

        it "returns an error if missing perceived free trial duration unit" do
          free_trial_membership_params[:perceived_free_trial_duration].delete(:unit)

          _, error = Purchase::CreateService.new(
            product:,
            params: free_trial_membership_params
          ).perform

          expect(error).to eq "Invalid free trial information provided. Please try again."
        end

        it "returns an error if perceived free trial duration amount is incorrect" do
          free_trial_membership_params[:perceived_free_trial_duration][:amount] = 3

          purchase, error = Purchase::CreateService.new(
            product:,
            params: free_trial_membership_params
          ).perform

          expect(error).to eq "The product's free trial has changed, please refresh the page!"
          expect(purchase).to be_present
        end

        it "returns an error if perceived free trial duration unit is incorrect" do
          free_trial_membership_params[:perceived_free_trial_duration][:unit] = "month"

          purchase, error = Purchase::CreateService.new(
            product:,
            params: free_trial_membership_params
          ).perform

          expect(error).to eq "The product's free trial has changed, please refresh the page!"
          expect(purchase).to be_present
        end
      end
    end

    describe "test purchases" do
      before do
        product.user = user
        product.save!
      end

      it "allows the buyer to test-purchase a subscription" do
        expect do
          expect do
            purchase, _ = Purchase::CreateService.new(
              product:,
              params: tiered_membership_params,
              buyer: user
            ).perform

            expect(purchase.purchase_state).to eq "test_successful"
            expect(purchase.succeeded_at).to be_present

            expect(purchase.subscription.is_test_subscription).to be(true)
            expect(purchase.subscription.cancelled_by_buyer).to be(false)
          end.to change { UrlRedirect.count }.from(0).to(1)
        end.to_not change { user.unpaid_balance_cents }
      end
    end
  end

  context "when purchase is a gift" do
    let(:country_field) { create(:custom_field, products: [product], name: "country") }
    let(:zip_field) { create(:custom_field, products: [product], name: "zip") }

    let(:gift_params) do
      params[:is_gift] = "true"
      params[:gift] = {
        gifter_email: "gifter@gumroad.com",
        giftee_email: "giftee@gumroad.com",
        gift_note: "Happy birthday!",
      }
      params[:purchase][:email] = "gifter@gumroad.com"
      params[:custom_fields] = [
        { id: country_field.external_id, value: "Brazil" },
        { id: zip_field.external_id, value: "123456" }
      ]
      params
    end

    it "creates a gift and associated gifter and giftee purchases with the right fields" do
      purchase, _ = Purchase::CreateService.new(product:, params: gift_params).perform

      gift = purchase.gift_given
      expect(gift).to be_successful
      expect(gift.gift_note).to eq "Happy birthday!"
      expect(gift.giftee_email).to eq "giftee@gumroad.com"
      expect(gift.gifter_email).to eq "gifter@gumroad.com"

      giftee_purchase = gift.giftee_purchase
      expect(giftee_purchase.quantity).to eq 1
      expect(giftee_purchase.purchase_state).to eq "gift_receiver_purchase_successful"
      expect(giftee_purchase.is_gift_sender_purchase).to be false
      expect(giftee_purchase.is_gift_receiver_purchase).to be true
      expect(giftee_purchase.price_cents).to eq 0
      expect(giftee_purchase.total_transaction_cents).to eq 0
      expect(giftee_purchase.displayed_price_cents).to eq 0
      expect(giftee_purchase.card_type).to be_nil
      expect(giftee_purchase.card_visual).to be_nil
      expect(giftee_purchase.custom_fields).to eq(
        [
          { name: "country", value: "Brazil", type: CustomField::TYPE_TEXT },
          { name: "zip", value: "123456", type: CustomField::TYPE_TEXT }
        ]
      )
      expect(giftee_purchase.street_address).to be_nil
      expect(giftee_purchase.city).to be_nil
      expect(giftee_purchase.state).to be_nil
      expect(giftee_purchase.zip_code).to be_nil
      expect(giftee_purchase.country).to be_nil
      expect(giftee_purchase.variant_attributes).to eq []

      # giftee purchase will have nil giftee_email, and gifter purchase will not
      gifter_purchase = gift.gifter_purchase
      expect(gifter_purchase.quantity).to eq 1
      expect(gifter_purchase.purchase_state).to eq "successful"
      expect(gifter_purchase.is_gift_sender_purchase).to be true
      expect(gifter_purchase.is_gift_receiver_purchase).to be false
      expect(gifter_purchase.card_type).to_not be_nil
      expect(gifter_purchase.card_visual).to_not be_nil
      expect(gifter_purchase.custom_fields).to eq(
        [
          { name: "country", value: "Brazil", type: CustomField::TYPE_TEXT },
          { name: "zip", value: "123456", type: CustomField::TYPE_TEXT }
        ]
      )
      expect(gifter_purchase.street_address).to be_nil
      expect(gifter_purchase.city).to be_nil
      expect(gifter_purchase.state).to be_nil
      expect(gifter_purchase.zip_code).to be_nil
      expect(gifter_purchase.country).to be_nil
      expect(gifter_purchase.variant_attributes).to eq []
    end

    it "sets the purchaser of giftee purchase to the user account with giftee email" do
      user = create(:user, email: gift_params[:gift][:giftee_email])

      purchase, _ = Purchase::CreateService.new(product:, params: gift_params).perform

      gift = purchase.gift_given
      expect(gift).to be_successful
      expect(gift.gifter_purchase).to be_successful
      expect(gift.giftee_purchase.gift_receiver_purchase_successful?).to be true
      expect(gift.giftee_purchase.purchaser_id).to eq user.id
    end

    it "creates a giftee and a gifter purchase successfully if user with giftee email doesn't exist" do
      purchase, _ = Purchase::CreateService.new(product:, params: gift_params).perform

      gift = purchase.gift_given
      expect(gift).to be_successful
      expect(gift.gifter_purchase).to be_successful
      expect(gift.giftee_purchase.gift_receiver_purchase_successful?).to be true
      expect(gift.giftee_purchase.purchaser_id).to be_nil
    end

    it "handles multi-quantity gifts" do
      gift_params[:purchase].merge!(quantity: 4, perceived_price_cents: 4 * price)

      purchase, _ = Purchase::CreateService.new(product:, params: gift_params).perform

      gift = purchase.gift_given
      giftee_purchase = gift.giftee_purchase
      expect(giftee_purchase.quantity).to eq 4
      expect(giftee_purchase.purchase_state).to eq "gift_receiver_purchase_successful"

      gifter_purchase = gift.gifter_purchase
      expect(gifter_purchase.quantity).to eq 4
      expect(gifter_purchase.purchase_state).to eq "successful"
    end

    it "handles gifts of customizable price products" do
      product.update!(customizable_price: true)

      purchase, _ = Purchase::CreateService.new(product:, params: gift_params).perform

      gift = purchase.gift_given
      expect(gift).to be_successful
    end

    context "with variants" do
      before :each do
        category = create(:variant_category, title: "sizes", link: product)
        @variant = create(:variant, name: "small", variant_category: category)

        gift_params[:variants] = [@variant.external_id]
      end

      it "associates the variants with the giftee purchase" do
        purchase, _ = Purchase::CreateService.new(product:, params: gift_params).perform

        gift = purchase.gift
        giftee_purchase = gift.giftee_purchase
        expect(gift.state).to eq "successful"
        expect(giftee_purchase.variant_attributes).to eq [@variant]
      end

      context "that have limited quantity" do
        it "succeeds" do
          @variant.update!(max_purchase_count: 1)

          purchase, _ = Purchase::CreateService.new(
            product:,
            params: gift_params
          ).perform

          expect(purchase).to be_successful
        end
      end

      context "that are out of stock" do
        it "returns an error" do
          create(:purchase, link: product, variant_attributes: [@variant])

          @variant.update!(max_purchase_count: 1)

          _, error = Purchase::CreateService.new(
            product:,
            params: gift_params
          ).perform

          expect(error).to eq "Sold out, please go back and pick another option."
        end
      end
    end

    context "with offer codes" do
      let(:offer_code) { create(:offer_code, products: [product], amount_cents: 200, max_purchase_count: 1) }
      before :each do
        gift_params[:purchase].merge!(discount_code: offer_code.code, perceived_price_cents: price - 200)
      end

      it "allows gifting until the offer code is used up" do
        purchase, _ = Purchase::CreateService.new(product:, params: gift_params).perform
        expect(purchase).to be_successful

        gift_params[:purchase][:email] = "newgifter@gumroad.com"
        gift_params[:gift].merge!(
          gifter_email: "newgifter@gumroad.com",
          giftee_email: "newgiftee@gumroad.com"
        )

        purchase, error = Purchase::CreateService.new(product:, params: gift_params).perform

        expect(purchase).not_to be_successful
        expect(error).to eq "Sorry, the discount code you wish to use has expired."
      end

      it "does not associate the offer code with the giftee purchase" do
        purchase, _ = Purchase::CreateService.new(product:, params: gift_params).perform

        giftee_purchase = purchase.gift.giftee_purchase
        expect(giftee_purchase.offer_code).to be_nil
      end
    end

    context "for a product that has already been gifted" do
      let!(:giftee_email) { "foo@foo.foo" }

      before :each do
        gift = create(:gift, giftee_email:)
        create(:purchase, link: product, gift_given: gift, purchaser: user, email: user.email, is_gift_sender_purchase: true)
        create(:purchase, link: product, gift_received: gift, is_gift_receiver_purchase: true)
      end

      it "can't be bought again by the giftee" do
        giftee = create(:user, email: giftee_email)
        params[:purchase][:email] = giftee_email

        _, error = Purchase::CreateService.new(
          product:,
          params:,
          buyer: giftee
        ).perform

        expect(error).to eq "You have already paid for this product. It has been emailed to you."
      end

      context "by a signed-in user" do
        it "can't be gifted again to the same person" do
          gift_params[:gift][:giftee_email] = giftee_email

          expect(ChargeProcessor).not_to receive(:create_payment_intent_or_charge!)

          purchase, error = Purchase::CreateService.new(
            product:,
            params: gift_params,
            buyer:
          ).perform

          gift = purchase.gift_given
          expect(error).to eq "You have already paid for this product. It has been emailed to you."
          expect(gift.state).to eq "failed"
          expect(gift.gifter_purchase).to be_nil
          expect(gift.giftee_purchase.purchase_state).to eq("gift_receiver_purchase_failed")
        end

        it "can be gifted again to other people" do
          gift_params[:gift][:giftee_email] = "newgiftee@gumroad.com"

          purchase, _ = Purchase::CreateService.new(
            product:,
            params: gift_params,
            buyer:
          ).perform

          gift = purchase.gift_given
          expect(gift.state).to eq "successful"
          expect(gift.gifter_purchase).not_to be_nil
          expect(gift.giftee_purchase).not_to be_nil
        end
      end

      context "by a signed-out user" do
        it "can't be gifted again to the same person" do
          gift_params[:gift][:giftee_email] = giftee_email

          expect(ChargeProcessor).not_to receive(:create_payment_intent_or_charge!)

          purchase, error = Purchase::CreateService.new(
            product:,
            params: gift_params
          ).perform

          gift = purchase.gift_given
          expect(error).to eq "You have already paid for this product. It has been emailed to you."
          expect(gift.state).to eq "failed"
          expect(gift.gifter_purchase).to be_nil
          expect(gift.giftee_purchase.purchase_state).to eq("gift_receiver_purchase_failed")
        end

        it "can be gifted again to other people" do
          gift_params[:gift][:giftee_email] = "newgiftee@gumroad.com"

          purchase, _ = Purchase::CreateService.new(
            product:,
            params: gift_params
          ).perform

          gift = purchase.gift_given
          expect(gift.state).to eq "successful"
          expect(gift.gifter_purchase).not_to be_nil
          expect(gift.giftee_purchase).not_to be_nil
        end
      end

      context "when is gifting a membership product" do
        let(:product) { create(:membership_product, price_cents: price) }

        it "create the subscription for the giftee, without credit card" do
          user = create(:user, email: gift_params[:gift][:giftee_email])
          purchase = nil

          expect do
            purchase, _ = Purchase::CreateService.new(product:, params: gift_params).perform
          end.to change { product.subscriptions.count }.by(1)
          expect(purchase.purchase_state).to eq "successful"

          subscription = product.subscriptions.last
          expect(subscription.link).to eq product
          expect(subscription.cancelled_at).to be(nil)
          expect(subscription.failed_at).to be(nil)
          expect(subscription.user).to eq user
          expect(subscription.credit_card).to be_nil
        end

        context "when product has a free trial enabled" do
          before do
            product.update!(free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week)
          end

          it "creates a subscription without free trial and charge the user immediately" do
            purchase = nil
            gift_params[:purchase][:is_original_subscription_purchase] = true

            expect do
              purchase, _ = Purchase::CreateService.new(product:, params: gift_params).perform
            end.to change { product.subscriptions.count }.by(1)

            expect(purchase.purchase_state).to eq "successful"
            expect(purchase.is_original_subscription_purchase).to be true
            expect(purchase.save_card).to be false
            expect(purchase.should_exclude_product_review).to be false

            subscription = product.subscriptions.last
            expect(subscription.link).to eq product
            expect(subscription.free_trial_ends_at).to be_nil
            expect(subscription.purchases.count).to eq 2
            expect(subscription.credit_card).to be_nil

            expect(Gift.last).to have_attributes(
              link: product,
              gift_note: gift_params[:gift][:gift_note],
            )

            expect(Gift.last.giftee_purchase).to have_attributes(
              email: gift_params[:gift][:giftee_email],
              is_original_subscription_purchase: false
            )
          end
        end
      end
    end

    describe "shipping" do
      before :each do
        product.update!(require_shipping: true)
        gift_params[:purchase].merge!(
          full_name: "Edgar Gumstein",
          street_address: "123 Gum Road",
          country: "US",
          state: "CA",
          city: "San Francisco",
          zip_code: "94117"
        )
      end

      it "records the shipping info in the giftee purchase" do
        purchase, _ = Purchase::CreateService.new(product:, params: gift_params).perform

        giftee_purchase = purchase.gift.giftee_purchase
        expect(giftee_purchase.full_name).to eq "Edgar Gumstein"
        expect(giftee_purchase.street_address).to eq "123 Gum Road"
        expect(giftee_purchase.country).to eq "United States"
        expect(giftee_purchase.state).to eq "CA"
        expect(giftee_purchase.city).to eq "San Francisco"
        expect(giftee_purchase.zip_code).to eq "94117"
      end

      it "creates a shipment" do
        purchase, _ = Purchase::CreateService.new(product:, params: gift_params).perform

        expect(purchase.shipment).to be_present
      end
    end

    context "when given giftee ID instead of email" do
      let(:giftee) { create(:user) }

      before do
        gift_params[:gift].delete(:giftee_email)
        gift_params[:gift][:giftee_id] = giftee.external_id
      end

      it "finds the giftee" do
        purchase, _ = Purchase::CreateService.new(product:, params: gift_params).perform

        expect(purchase.gift.giftee_email).to eq giftee.email
        expect(purchase.gift.is_recipient_hidden).to eq true
        expect(purchase.gift.giftee_purchase.purchaser).to eq giftee
      end
    end

    context "but is missing giftee email" do
      it "returns an error message" do
        gift_params[:gift][:giftee_email] = nil

        expect do
          expect(ChargeProcessor).not_to receive(:create_payment_intent_or_charge!)
          _, error = Purchase::CreateService.new(product:, params: gift_params).perform
          expect(error).to eq "Giftee email can't be blank"
        end.to_not change(Gift, :count)
      end
    end

    context "but has an invalid giftee email" do
      it "returns an error message" do
        gift_params[:gift][:giftee_email] = "foo"

        expect do
          expect(ChargeProcessor).not_to receive(:create_payment_intent_or_charge!)
          _, error = Purchase::CreateService.new(product:, params: gift_params).perform
          expect(error).to eq "Giftee email is invalid"
        end.to_not change(Gift, :count)
      end
    end

    context "but current user is the creator" do
      it "returns an error message" do
        expect do
          _, error = Purchase::CreateService.new(
            product:,
            params: gift_params,
            buyer: product.user
          ).perform
          expect(error).to eq "Test gift purchases have not been enabled yet."
        end.to_not change(Purchase, :count)
      end
    end

    context "but the gifter and giftee emails are the same" do
      it "returns an error message" do
        gifter_email = gift_params[:purchase][:email]
        gift_params[:gift][:giftee_email] = gifter_email

        expect do
          _, error = Purchase::CreateService.new(product:, params: gift_params).perform

          expect(error).to eq "You cannot gift a product to yourself. Please try gifting to another email."
        end.not_to change { Gift.count }
      end
    end

    context "but product cannot be gifted" do
      it "returns an error message" do
        not_giftable = create(:product, is_in_preorder_state: true)

        _, error = Purchase::CreateService.new(product: not_giftable, params: gift_params).perform

        expect(error).to eq "Gifting is not yet enabled for pre-orders."
      end
    end

    context "but the gift fails to save" do
      it "returns an error message" do
        gift_params[:gift].merge!(giftee_email: nil, gifter_email: nil)

        _, error = Purchase::CreateService.new(product:, params: gift_params).perform

        expect(error).to eq "Giftee email can't be blank"
      end
    end

    context "but the charge is declined" do
      it "creates failed purchases and returns an error message" do
        gift_params[:purchase][:chargeable] = failed_chargeable
        purchase, error = Purchase::CreateService.new(product:, params: gift_params).perform

        expect(error).to eq("Your card was declined.")
        expect(purchase.purchase_state).to eq("failed")
        expect(purchase.gift_given.state).to eq("failed")
        expect(purchase.gift_given.giftee_purchase.purchase_state).to eq("gift_receiver_purchase_failed")
      end
    end

    context "but product only has one available" do
      before :each do
        product.update!(max_purchase_count: 1)
      end

      it "only allows one gift purchase" do
        purchase, _ = Purchase::CreateService.new(product:, params: gift_params).perform
        expect(purchase).to be_successful
        gift_params[:purchase][:email] = "newemail@gumroad.com"

        purchase, error = Purchase::CreateService.new(product:, params: gift_params).perform

        expect(purchase).not_to be_successful
        expect(error).to eq "You have already paid for this product. It has been emailed to you."
      end

      it "does not allow purchase if quantity exceeds product availability" do
        gift_params[:purchase][:quantity] = 2

        purchase, error = Purchase::CreateService.new(product:, params: gift_params).perform

        expect(purchase).not_to be_successful
        expect(error).to eq "You have chosen a quantity that exceeds what is available."
      end
    end
  end

  context "when purchase is a test purchase" do
    it "sets the correct purchase_state and succeeded_at" do
      expect do
        purchase, _ = Purchase::CreateService.new(
          product:,
          params:,
          buyer: user,
        ).perform

        expect(purchase.purchase_state).to eq "test_successful"
        expect(purchase.succeeded_at).to be_present
      end.to change { Purchase.count }.by 1
    end
  end

  context "with offer code" do
    let(:discount_cents) { 200 }
    let(:discounted_price) { price - discount_cents }

    it "applies a valid offer code" do
      offer_code = create(:offer_code, products: [product], amount_cents: discount_cents)

      params[:purchase].merge!(
        discount_code: offer_code.code,
        perceived_price_cents: discounted_price,
      )

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase).to be_successful
      expect(purchase.price_cents).to eq discounted_price
      expect(purchase.total_transaction_cents).to eq discounted_price
      expect(purchase.offer_code).to eq offer_code
      discount = purchase.purchase_offer_code_discount
      expect(discount).to be
      expect(discount.offer_code_amount).to eq 200
      expect(discount.offer_code_is_percent).to eq false
      expect(discount.pre_discount_minimum_price_cents).to eq discounted_price + discount_cents
    end

    it "applies a valid universal offer code" do
      offer_code = create(:universal_offer_code, code: "uni", user:, amount_cents: discount_cents)

      params[:purchase].merge!(
        discount_code: offer_code.code,
        perceived_price_cents: discounted_price,
      )

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase).to be_successful
      expect(purchase.price_cents).to eq discounted_price
      expect(purchase.total_transaction_cents).to eq discounted_price
    end

    it "allows non-ascii offer codes" do
      offer_code = create(:offer_code, products: [product], amount_cents: discount_cents, code: "ÕËëæç")

      params[:purchase].merge!(
        discount_code: offer_code.code,
        perceived_price_cents: discounted_price,
      )

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase).to be_successful
      expect(purchase.price_cents).to eq discounted_price
      expect(purchase.total_transaction_cents).to eq discounted_price
    end

    it "allows non-integer offer code amounts" do
      product.update!(price_cents: 350)

      offer_code = create(:offer_code, products: [product], amount_cents: 151)

      params[:purchase].merge!(
        discount_code: offer_code.code,
        perceived_price_cents: 350 - 151,
        price_range: 1.99
      )

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase.purchase_state).to eq "successful"
      expect(purchase.price_cents).to eq 199
      expect(purchase.total_transaction_cents).to eq 199
      discount = purchase.purchase_offer_code_discount
      expect(discount).to be
      expect(discount.offer_code_amount).to eq 151
      expect(discount.offer_code_is_percent).to eq false
      expect(discount.pre_discount_minimum_price_cents).to eq 350
    end

    it "allows purchases with offer codes in different currencies" do
      %i[eur gbp aud inr cad hkd sgd twd nzd].each do |currency|
        product.update!(price_currency_type: currency, price_cents: 15_000)
        offer_code = create(:offer_code, code: currency, currency_type: currency, products: [product], amount_cents: 3_000)
        params[:purchase].merge!(
          discount_code: offer_code.code,
          perceived_price_cents: 12_000,
          price_range: 120,
          ip_address: Faker::Internet.ip_v4_address,
          browser_guid: SecureRandom.uuid, # don't make Stripe think these are duplicate purchases
          chargeable: CardParamsHelper.build_chargeable(
            StripePaymentMethodHelper.success.to_stripejs_params,
            browser_guid
          )
        )

        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.purchase_state).to eq "successful"
        expect(purchase.price_cents).to eq get_usd_cents(currency.to_s, 12_000)
        expect(purchase.total_transaction_cents).to eq get_usd_cents(currency.to_s, 12_000)
      end
    end

    it "updates the used_count value for the offer code" do
      offer_code = create(:offer_code, products: [product], amount_cents: discount_cents)

      params[:purchase].merge!(
        discount_code: offer_code.code,
        perceived_price_cents: discounted_price
      )

      Purchase::CreateService.new(product:, params:).perform

      expect(offer_code.reload.times_used).to eq 1
    end

    it "fails if the offer code is deleted" do
      offer_code = create(:offer_code, products: [product], amount_cents: discount_cents, deleted_at: Time.current)

      params[:purchase].merge!(
        discount_code: offer_code.code,
        perceived_price_cents: discounted_price
      )

      purchase, error = Purchase::CreateService.new(product:, params:).perform

      expect(error).to eq "Sorry, the discount code you wish to use is invalid."
      expect(purchase.purchase_state).to eq "failed"
      expect(purchase.error_code).to eq "offer_code_invalid"
    end

    it "fails if the amount paid is less than it should be" do
      offer_code = create(:offer_code, products: [product], amount_cents: discount_cents)

      params[:purchase].merge!(
        discount_code: offer_code.code,
        perceived_price_cents: discounted_price
      )

      [0, 0.9].each do |price_range|
        params[:purchase].merge!(price_range:)

        purchase, error = Purchase::CreateService.new(product:, params:).perform

        expect(error).to eq "Please enter an amount greater than or equal to the minimum."
        expect(purchase.error_code).to eq "price_cents_too_low"
        expect(purchase.purchase_state).to eq "failed"
      end
    end

    it "fails if the amount paid is less than it should be in any currency" do
      %i[eur gbp aud inr cad hkd sgd twd nzd].each do |currency|
        product.update!(price_currency_type: currency, price_cents: 15_000)
        offer_code = create(:offer_code, code: currency, currency_type: currency, products: [product], amount_cents: 3_000)
        params[:purchase].merge!(
          discount_code: offer_code.code,
          perceived_price_cents: 12_000,
          price_range: 119.99
        )

        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.purchase_state).to eq "failed"
        expect(purchase.error_code).to eq "price_cents_too_low"
      end
    end

    it "fails if offer code has reached max purchase count" do
      offer_code = create(:offer_code, products: [product], amount_cents: discount_cents, max_purchase_count: 1)
      create(:purchase, offer_code:)

      params[:purchase].merge!(
        discount_code: offer_code.code,
        perceived_price_cents: discounted_price,
        price_range: 1,
        quantity: 3
      )

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase.purchase_state).to eq "failed"
      expect(purchase.error_code).to eq "offer_code_sold_out"
    end

    describe "multi-quantity" do
      let(:offer_code) { create(:offer_code, products: [product], amount_cents: 100, max_purchase_count: 2) }

      it "allows multi-quantity purchases" do
        total_price = (price - 100) * 2
        params[:purchase].merge!(
          discount_code: offer_code.code,
          perceived_price_cents: total_price,
          quantity: 2
        )

        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.purchase_state).to eq "successful"
        expect(purchase.price_cents).to eq total_price
        expect(purchase.total_transaction_cents).to eq total_price

        discount = purchase.purchase_offer_code_discount
        expect(discount).to be
        expect(discount.offer_code_amount).to eq 100
        expect(discount.offer_code_is_percent).to eq false
        expect(discount.pre_discount_minimum_price_cents).to eq price
      end

      it "fails when quantity exceeds offer code availability" do
        total_price = (price - 100) * 3
        params[:purchase].merge!(
          discount_code: offer_code.code,
          perceived_price_cents: total_price,
          price_range: 1,
          quantity: 3
        )

        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.purchase_state).to eq "failed"
        expect(purchase.error_code).to eq "exceeding_offer_code_quantity"
      end
    end
  end

  context "with customizable price" do
    before :each do
      product.update!(customizable_price: true, price_cents: 0)
      params[:purchase].delete(:perceived_price_cents)
    end

    it "allows a free purchase" do
      params[:purchase].merge!(price_range: 0)

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase).to be_successful
    end

    it "allows a purchase above minimum for the currency" do
      params[:purchase].merge!(price_range: 1_00) # USD minimum is $0.99

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase).to be_successful
    end

    it "does not allow a purchase below minimum for the currency" do
      params[:purchase][:price_range] = 0.98 # USD minimum is $0.99

      purchase, _ = Purchase::CreateService.new(product:, params:).perform

      expect(purchase).not_to be_successful
    end
  end

  describe "repeat purchases" do
    it "does not allow a repeat purchase from the same user" do
      Purchase::CreateService.new(product:, params:, buyer:).perform

      expect do
        _, error = Purchase::CreateService.new(product:, params:, buyer:).perform

        expect(error).to eq "You have already paid for this product. It has been emailed to you."
      end.not_to change { Purchase.count }
    end
  end

  context "when max price in non-USD" do
    let(:max) { (get_rate("gbp").to_f * User::MAX_PRICE_USD_CENTS_UNLESS_VERIFIED).floor }

    it "allows unverified purchase up to $1000" do
      user.update!(verified: false)
      product.update!(price_currency_type: "gbp", price_cents: max - 100)
      params[:purchase].merge!(perceived_price_cents: max - 100)

      expect do
        Purchase::CreateService.new(product:, params:).perform
      end.to change { Purchase.successful.count }.by(1)
    end

    it "allows verified purchase over $1000" do
      user.update!(verified: true)
      product.update!(price_currency_type: "gbp", price_cents: max + 100)
      params[:purchase].merge!(perceived_price_cents: max + 100)

      expect do
        Purchase::CreateService.new(product:, params:).perform
      end.to change { Purchase.successful.count }.by(1)
    end
  end

  describe "payment methods" do
    context "using paypal order api" do
      it "sets paypal_order_id, purchase state successful and sets save_card attribute" do
        paypal_charge_double = double
        allow(paypal_charge_double).to receive(:flow_of_funds).and_return({})
        paypal_charge_intent_double = double
        allow(paypal_charge_intent_double).to receive(:succeeded?).and_return(true)
        allow(paypal_charge_intent_double).to receive(:requires_action?).and_return(false)
        allow(paypal_charge_intent_double).to receive(:charge).and_return(paypal_charge_double)
        allow_any_instance_of(Purchase).to receive(:create_charge_intent).and_return(paypal_charge_intent_double)
        allow_any_instance_of(Purchase).to receive(:save_charge_data)
        allow_any_instance_of(Purchase).to receive(:increment_sellers_balance!).and_return(true)
        allow_any_instance_of(Purchase).to receive(:financial_transaction_validation).and_return(true)
        paypal_order_id = "94X4WXHSGMSA2"
        base_params[:purchase][:paypal_order_id] = paypal_order_id
        base_params[:purchase][:chargeable] = CardParamsHelper.build_chargeable(
          { billing_agreement_id: "B-12345678910" },
          browser_guid
        )
        base_params[:purchase][:save_card] = true

        purchase, _ = Purchase::CreateService.new(
          product:,
          params: base_params
        ).perform

        expect(purchase.paypal_order_id).to eq paypal_order_id
        expect(purchase.successful?).to be true
        expect(purchase.save_card).to eq(true)
      end
    end

    context "using stripejs" do
      it "sets the card data handling mode" do
        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.card_data_handling_mode).to eq CardDataHandlingMode::TOKENIZE_VIA_STRIPEJS
      end

      it "sets the chargeable" do
        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.chargeable).to eq successful_card_chargeable
      end

      context "when purchase fails" do
        it "sets the proper state on the purchase" do
          base_params[:purchase][:chargeable] = failed_chargeable

          purchase, _ = Purchase::CreateService.new(product:, params: base_params).perform

          expect(purchase.purchase_state).to eq "failed"
          expect(purchase.card_country).to be_present
          expect(purchase.stripe_fingerprint).to be_present
        end

        it "sets the proper state on the purchase for a multi-quantity purchase" do
          base_params[:purchase].merge!(
            chargeable: failed_chargeable,
            perceived_price_cents: product.price_cents * 5,
            quantity: 5
          )

          purchase, _ = Purchase::CreateService.new(product:, params: base_params).perform

          expect(purchase.purchase_state).to eq "failed"
          expect(purchase.quantity).to eq 5
          expect(purchase.card_country).to be_present
          expect(purchase.stripe_fingerprint).to be_present
        end
      end

      context "when purchase succeeds" do
        it "sets the proper state on the purchase" do
          purchase, _ = Purchase::CreateService.new(product:, params:).perform

          expect(purchase.purchase_state).to eq "successful"
          expect(purchase.card_country).to be_present
          expect(purchase.stripe_fingerprint).to be_present
          expect(purchase.succeeded_at).to be_present
        end

        it "sets the proper state on the purchase for a multi-quantity purchase" do
          params[:purchase].merge!(perceived_price_cents: product.price_cents * 5, quantity: 5)

          purchase, _ = Purchase::CreateService.new(product:, params:).perform

          expect(purchase.purchase_state).to eq "successful"
          expect(purchase.quantity).to eq 5
          expect(purchase.card_country).to be_present
          expect(purchase.stripe_fingerprint).to be_present
          expect(purchase.succeeded_at).to be_present
        end
      end
    end
  end

  describe "API notifications" do
    context "digital product" do
      it "enqueues the post to ping job for 'sale' resource" do
        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(purchase.id, nil)
      end
    end

    context "membership product" do
      let(:product) { create(:membership_product, price_cents: price) }
      let(:tiered_membership_params) do
        subscription_params[:purchase][:is_original_subscription_purchase] = true
        subscription_params[:price_id] = product.default_price.external_id
        subscription_params[:variants] = [product.tiers.first.external_id]
        subscription_params
      end

      it "enqueues the post to ping job for 'sale' resource" do
        purchase, _ = Purchase::CreateService.new(
          product:,
          params: tiered_membership_params
        ).perform

        expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(purchase.id, nil)
      end

      context "with free trial enabled" do
        it "enqueues the post to ping job for 'sale' resource" do
          product.update!(free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week)
          tiered_membership_params[:purchase][:is_free_trial_purchase] = true
          tiered_membership_params[:perceived_free_trial_duration] = { amount: product.free_trial_duration_amount, unit: product.free_trial_duration_unit }

          purchase, _ = Purchase::CreateService.new(
            product:,
            params: tiered_membership_params
          ).perform

          expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(purchase.id, nil)
        end
      end
    end
  end

  context "with invalid params" do
    context "such as an invalid purchase price" do
      it "returns an error message" do
        params[:purchase].merge!(perceived_price_cents: Purchase::MAX_PRICE_RANGE.last + 1)

        _, error = Purchase::CreateService.new(product:, params:).perform

        expect(error).to eq "Purchase price is invalid. Please check the price."
      end
    end

    context "such as invalid U.S. zip code when eligible for U.S. sales tax" do
      it "returns an error" do
        user = create(:user)
        product = create(:physical_product, user:)

        params[:purchase].merge!(
          country: Compliance::Countries::USA.alpha2,
          zip_code: "00000"
        )

        _, error = Purchase::CreateService.new(product:, params:).perform

        expect(error).to eq "You entered a ZIP Code that doesn't exist within your country."
      end
    end

    context "such as invalid variants" do
      it "returns an error message" do
        variant_for_other_product = create(:variant, name: "Small")

        params[:variants] = [variant_for_other_product.external_id]

        _, error = Purchase::CreateService.new(product:, params:).perform

        expect(error).to eq "The product's variants have changed, please refresh the page!"
      end
    end
  end

  describe "coffee products" do
    context "no variants selected" do
      it "doesn't return an error message" do
        product.update!(native_type: Link::NATIVE_TYPE_COFFEE)
        create(:variant, variant_category: create(:variant_category, link: product), price_difference_cents: 100)

        params[:variants] = []

        purchase, error = Purchase::CreateService.new(product:, params:).perform

        expect(purchase).to be_successful
        expect(error).to be_nil
      end
    end
  end

  describe "call products", :freeze_time do
    before { travel_to(DateTime.parse("May 1 2024 UTC")) }

    let!(:call_product) { create(:call_product, :available_for_a_year, price_cents: price) }
    let!(:call_duration) { 30.minutes }
    let!(:call_option_30_minute) { create(:variant, name: "30 minute", duration_in_minutes: call_duration.in_minutes, variant_category: call_product.variant_categories.first) }
    let!(:call_start_time) { DateTime.parse("May 1 2024 10:28:30.123456 UTC") }
    let!(:normalized_call_start_time) { DateTime.parse("May 1 2024 10:28:00 UTC") }

    it "create a call with the correct start and end time" do
      params[:variants] = [call_option_30_minute.external_id]
      params[:call_start_time] = call_start_time.iso8601

      purchase, error = Purchase::CreateService.new(product: call_product, params:).perform

      expect(error).to be_nil
      expect(purchase.call.start_time).to eq(normalized_call_start_time)
      expect(purchase.call.end_time).to eq(normalized_call_start_time + call_duration)
    end

    it "allows gifting a call" do
      params[:is_gift] = true
      params[:gift] = {
        gifter_email: "gifter@gumroad.com",
        giftee_email: "giftee@gumroad.com",
        gift_note: "Happy birthday!",
      }
      params[:variants] = [call_option_30_minute.external_id]
      params[:call_start_time] = call_start_time.iso8601

      purchase, error = Purchase::CreateService.new(product: call_product, params:).perform

      expect(error).to be_nil
      expect(purchase.call.start_time).to eq(normalized_call_start_time)
      expect(purchase.call.end_time).to eq(normalized_call_start_time + call_duration)

      expect(purchase.gift_given).to be_successful
      giftee_purchase = purchase.gift_given.giftee_purchase
      expect(giftee_purchase.call.start_time).to eq(normalized_call_start_time)
      expect(giftee_purchase.call.end_time).to eq(normalized_call_start_time + call_duration)
    end

    context "missing variant selection" do
      it "returns an error" do
        params[:variants] = []
        params[:call_start_time] = call_start_time.iso8601

        _, error = Purchase::CreateService.new(product: call_product, params:).perform

        expect(error).to eq("Please select a start time.")
      end
    end

    context "missing call start time" do
      it "returns an error" do
        params[:variants] = [call_option_30_minute.external_id]
        params[:call_start_time] = nil

        _, error = Purchase::CreateService.new(product: call_product, params:).perform

        expect(error).to eq("Please select a start time.")
      end
    end

    context "invalid start time" do
      it "returns an error" do
        params[:variants] = [call_option_30_minute.external_id]
        params[:call_start_time] = "invalid"

        _, error = Purchase::CreateService.new(product: call_product, params:).perform

        expect(error).to eq("Please select a start time.")
      end
    end
  end

  describe "inventory protection" do
    let(:price) { 0 }
    let(:max_purchase_count) { 1 }

    it "prevents several parallel purchases to take more than the available inventory" do
      purchase_1, error_1, purchase_2, error_2 = Array.new(4)
      params_1 = base_params.deep_merge(purchase: { email: "purchaser_1@gumroad.com", browser_guid: SecureRandom.uuid })
      params_2 = base_params.deep_merge(purchase: { email: "purchaser_2@gumroad.com", browser_guid: SecureRandom.uuid })

      [
        Thread.new { purchase_1, error_1 = Purchase::CreateService.new(product:, params: params_1).perform },
        Thread.new { purchase_2, error_2 = Purchase::CreateService.new(product:, params: params_2).perform }
      ].each(&:join)

      expect(purchase_1.purchase_state).to eq("successful")
      expect(error_1).to eq(nil)
      # The following also tests that the semaphore was unlocked after processing purchase_1
      expect(purchase_2.purchase_state).to eq("failed")
      expect(error_2).to match(/sold out/i)
    end

    context "when an unexpected error is raised" do
      # Tests the `ensure` part of `#perform`
      it "automatically unlocks semaphore" do
        service = Purchase::CreateService.new(product:, params: base_params)
        expect(service).to receive(:build_purchase).and_raise(StandardError.new)
        expect { service.perform }.to raise_error(StandardError)

        # Another purchase can be made normally
        purchase, error = Purchase::CreateService.new(product:, params: base_params).perform
        expect(purchase.purchase_state).to eq("successful")
        expect(error).to eq(nil)
      end
    end

    context "when a lock can't be acquired before timeout" do
      let(:max_purchase_count) { 2 }

      # Tests a situation where too many people try to buy the same product at the same time.
      it "returns generic error" do
        Thread.new do # use new ActiveRecord connections
          timeout = 1.second
          stub_const("Purchase::CreateService::INVENTORY_LOCK_ACQUISITION_TIMEOUT", timeout)
          purchase_1, error_2 = Array.new(2)
          params_1 = base_params.deep_merge(purchase: { email: "purchaser_1@gumroad.com", browser_guid: SecureRandom.uuid })
          params_2 = base_params.deep_merge(purchase: { email: "purchaser_2@gumroad.com", browser_guid: SecureRandom.uuid })

          threads = []
          threads << Thread.new do
            service_1 = Purchase::CreateService.new(product:, params: params_1)
            # Simulate a situation where processing a purchase takes more than the allowed time
            allow(service_1).to receive(:build_purchase).with(any_args).and_wrap_original do |m, *args|
              $first_purchase_is_processing = true
              sleep timeout + 0.5 # => longer than the acquisition timeout, so the other purchase's lock acquisition will timeout
              m.call(*args)
            end
            purchase_1, _ = service_1.perform
          end
          threads << Thread.new do
            sleep(0.1) while $first_purchase_is_processing.nil? # waits until first thread is locking the product inventory
            _, error_2 = Purchase::CreateService.new(product:, params: params_2).perform
          end

          sleep(0.1) while threads.any?(&:alive?)
          expect(purchase_1.purchase_state).to eq("successful")
          expect(error_2).to match(/try again/i)

          # Test that the second purchaser can indeed try again successfully afterwards
          purchase_2, error_2 = Purchase::CreateService.new(product:, params: params_2).perform
          expect(purchase_2.purchase_state).to eq("successful")
          expect(error_2).to eq(nil)
        end.join
      end
    end
  end

  describe "custom fields" do
    let(:text_field) { create(:custom_field, products: [product], name: "Country", field_type: CustomField::TYPE_TEXT) }
    let(:checkbox_field) { create(:custom_field, products: [product], name: "Is that your real country?", field_type: CustomField::TYPE_CHECKBOX, required: true) }
    let(:terms_field) { create(:custom_field, products: [product], name: "https://example.com/terms", field_type: CustomField::TYPE_TERMS) }

    it "creates a purchase with custom fields" do
      params[:custom_fields] = [
        { id: text_field.external_id, value: "NZ" },
        { id: checkbox_field.external_id, value: true },
        { id: terms_field.external_id, value: true }
      ]

      expect do
        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.purchase_state).to eq("successful")
        expect(purchase.purchase_custom_fields.count).to eq(3)
        expect(purchase.custom_fields).to eq(
          [
            { name: "Country", value: "NZ", type: CustomField::TYPE_TEXT },
            { name: "Is that your real country?", value: true, type: CustomField::TYPE_CHECKBOX },
            { name: "https://example.com/terms", value: true, type: CustomField::TYPE_TERMS },
          ]
        )
      end.to change { Purchase.count }.by 1
    end

    it "raises an error when a custom field is invalid" do
      params[:custom_fields] = [
        { id: text_field.external_id, value: "NZ" },
        { id: checkbox_field.external_id, value: false },
        { id: terms_field.external_id, value: true }
      ]

      purchase, error_message = Purchase::CreateService.new(product:, params:).perform

      expect(purchase).not_to be_persisted
      expect(error_message).to eq("Purchase custom fields is invalid")
    end

    context "with bundle purchases" do
      let(:product) { create(:product, :bundle) }
      let(:bundle_terms_field) { create(:custom_field, products: [product.bundle_products.second.product], name: "https://example.com/terms2", field_type: CustomField::TYPE_TERMS) }

      before do
        text_field.products << product.bundle_products.first.product

        params[:bundle_products] = [
          {
            product_id: product.bundle_products.first.product.external_id,
            variant_id: nil,
            quantity: 1,
            custom_fields: [{ id: text_field.external_id, value: "NZ" }],
          },
          {
            product_id: product.bundle_products.second.product.external_id,
            variant_id: nil,
            quantity: 1,
            custom_fields: [{ id: bundle_terms_field.external_id, value: true }],
          }
        ]
        params[:purchase][:perceived_price_cents] = 100
        params[:custom_fields] = [
          { id: checkbox_field.external_id, value: true },
          { id: terms_field.external_id, value: true },
        ]
      end

      it "creates a purchase with bundle product custom fields" do
        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.purchase_state).to eq("successful")
        expect(purchase.purchase_custom_fields.count).to eq(2)
        expect(purchase.custom_fields).to eq(
          [
            { name: "Is that your real country?", value: true, type: CustomField::TYPE_CHECKBOX },
            { name: "https://example.com/terms", value: true, type: CustomField::TYPE_TERMS },
          ]
        )
        expect(purchase.product_purchases.count).to eq(2)
        expect(purchase.product_purchases.first.custom_fields).to eq(
          [
            { name: "Country", value: "NZ", type: CustomField::TYPE_TEXT }
          ]
        )
        expect(purchase.product_purchases.second.custom_fields).to eq(
          [
            { name: "https://example.com/terms2", value: true, type: CustomField::TYPE_TERMS }
          ]
        )
      end

      it "saves custom fields on the original purchase when SCA is required" do
        allow_any_instance_of(StripeChargeIntent).to receive(:requires_action?).and_return(true)

        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.purchase_state).to eq "in_progress"
        expect(purchase.purchase_custom_fields.count).to eq 4
        expect(purchase.purchase_custom_fields.first).to have_attributes(name: "Is that your real country?", value: true, bundle_product: nil)
        expect(purchase.purchase_custom_fields.second).to have_attributes(name: "https://example.com/terms", value: true, bundle_product: nil)
        expect(purchase.purchase_custom_fields.third).to have_attributes(name: "Country", value: "NZ", bundle_product: product.bundle_products.first)
        expect(purchase.purchase_custom_fields.fourth).to have_attributes(name: "https://example.com/terms2", value: true, bundle_product: product.bundle_products.second)
      end

      it "raises an error when a bundle product custom field is invalid" do
        params[:bundle_products].second[:custom_fields] = [
          { id: bundle_terms_field.external_id, value: false }
        ]

        purchase, error_message = Purchase::CreateService.new(product:, params:).perform

        expect(purchase).not_to be_persisted
        expect(error_message).to eq("Purchase custom fields is invalid")
      end
    end
  end

  describe "purchase on a Brazilian Stripe Connect account" do
    before do
      product.user.update!(check_merchant_account_is_linked: true)
      create(:merchant_account_stripe_connect, charge_processor_merchant_id: "acct_1QADdCGy0w4tFIUe", country: "BR", user: product.user)
      params[:purchase][:chargeable] = CardParamsHelper.build_chargeable(
        StripePaymentMethodHelper.success.with_zip_code(zip_code).to_stripejs_params.merge(product_permalink: product.unique_permalink),
        browser_guid
      )
      params[:purchase][:chargeable].prepare!
    end

    it "creates a purchase and sets Gumroad fees and taxes as 0" do
      expect do
        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.purchase_state).to eq "successful"
        expect(purchase.card_country).to be_present
        expect(purchase.stripe_fingerprint).to be_present
        expect(purchase.fee_cents).to eq 0
        expect(purchase.gumroad_tax_cents).to eq 0
        expect(purchase.tax_cents).to eq 0
      end.to change { Purchase.count }.by 1
    end

    it "creates a purchase with error if it has an affiliate" do
      expect do
        direct_affiliate = build(:direct_affiliate, seller: product.user)
        direct_affiliate.save(validate: false)
        params[:purchase][:affiliate_id] = direct_affiliate.id

        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.reload.purchase_state).to eq "failed"
        expect(purchase.error_code).to eq PurchaseErrorCode::BRAZILIAN_MERCHANT_ACCOUNT_WITH_AFFILIATE
      end.to change { Purchase.count }.by 1
    end
  end

  describe "seller has custom fee set" do
    before do
      product.user.update!(custom_fee_per_thousand: 50)
      params[:purchase][:chargeable] = CardParamsHelper.build_chargeable(
        StripePaymentMethodHelper.success.with_zip_code(zip_code).to_stripejs_params.merge(product_permalink: product.unique_permalink),
        browser_guid
      )
      params[:purchase][:chargeable].prepare!
    end

    it "creates a purchase and sets Gumroad fee as per the custom fee applicable to the seller" do
      expect do
        purchase, _ = Purchase::CreateService.new(product:, params:).perform

        expect(purchase.purchase_state).to eq "successful"
        expect(purchase.card_country).to be_present
        expect(purchase.stripe_fingerprint).to be_present
        expect(purchase.fee_cents).to eq 127 # 5% of $6 + 50c + 2.9% of $6 + 30c
        expect(purchase.gumroad_tax_cents).to eq 0
        expect(purchase.tax_cents).to eq 0
      end.to change { Purchase.count }.by 1
    end
  end

  describe "commission deposit purchase" do
    let(:commission_product) { create(:commission_product) }

    it "sets is_commission_deposit_purchase to true" do
      purchase, _ = Purchase::CreateService.new(product: commission_product, params:).perform

      expect(purchase.is_commission_deposit_purchase).to be true
    end
  end

  describe "tipping" do
    before do
      params[:tip_cents] = 100
      params[:purchase][:perceived_price_cents] = 700
      params[:purchase][:price_cents] = 700
    end

    context "when tipping is enabled" do
      before { user.update!(tipping_enabled: true) }

      it "creates a purchase with a tip" do
        purchase, _ = Purchase::CreateService.new(product:, params:).perform


        expect(purchase).to be_successful
        expect(purchase.price_cents).to eq 700
        expect(purchase.tip.value_cents).to eq 100
      end

      context "when tip is too large" do
        before do
          params[:tip_cents] = 100
          params[:purchase][:perceived_price_cents] = 600
          params[:purchase][:price_cents] = 600
        end

        it "raises an error" do
          purchase, error = Purchase::CreateService.new(product:, params:).perform

          expect(purchase).to_not be_successful
          expect(error).to eq("Tip is too large for this purchase")
        end
      end

      context "when product is a membership" do
        let(:product) { create(:membership_product) }

        it "raises an error" do
          purchase, error = Purchase::CreateService.new(product:, params:).perform

          expect(purchase).to_not be_successful
          expect(error).to eq("Tip is not allowed for this product")
        end
      end

      context "when tip value is 0" do
        before do
          params[:tip_cents] = 0
          params[:purchase][:perceived_price_cents] = 600
          params[:purchase][:price_cents] = 600
        end

        it "creates a purchase without a tip" do
          purchase, _ = Purchase::CreateService.new(product:, params:).perform

          expect(purchase).to be_successful
          expect(purchase.price_cents).to eq 600
          expect(purchase.tip).to be_nil
        end
      end
    end

    context "when tipping is not enabled" do
      it "raises an error when attempting to add a tip" do
        purchase, error = Purchase::CreateService.new(product:, params:).perform

        expect(purchase).to_not be_successful
        expect(error).to eq("Tip is not allowed for this product")
      end
    end
  end

  describe "paying in installments" do
    let!(:installment_plan) { create(:product_installment_plan, link: product, number_of_installments: 3, recurrence: "monthly") }

    it "creates a purchase with installment plan" do
      params[:purchase][:perceived_price_cents] = 200
      params[:pay_in_installments] = true

      purchase, error = Purchase::CreateService.new(product:, params:).perform

      expect(error).to be_nil
      expect(purchase).to have_attributes(
        purchase_state: "successful",
        is_installment_payment: true,
        is_original_subscription_purchase: true
      )
      expect(purchase.subscription).to have_attributes(
        is_installment_plan: true,
        charge_occurrence_count: 3,
        recurrence: "monthly",
      )
      expect(purchase.subscription.credit_card).to be_present
      expect(purchase.subscription.last_payment_option.installment_plan).to eq(installment_plan)
    end

    it "fails when without an installment plan" do
      params[:purchase][:perceived_price_cents] = 200
      params[:pay_in_installments] = true
      product.installment_plan.mark_deleted!
      product.reload

      purchase, error = Purchase::CreateService.new(product:, params:).perform

      expect(error).to include("The price just changed!")
      expect(purchase).to have_attributes(
        purchase_state: "failed",
        is_installment_payment: false,
        is_original_subscription_purchase: false
      )
      expect(purchase.subscription).to be_nil
    end

    it "does not allow gifting an installment plan" do
      params[:purchase][:perceived_price_cents] = 200
      params[:pay_in_installments] = true
      params[:is_gift] = "true"
      params[:gift] = {
        gifter_email: "gifter@gumroad.com",
        giftee_email: "giftee@gumroad.com",
        gift_note: "Happy birthday!",
      }

      purchase, error = Purchase::CreateService.new(product:, params:).perform

      expect(purchase).to be_nil
      expect(error).to eq("Gift purchases cannot be on installment plans.")
    end
  end
end
