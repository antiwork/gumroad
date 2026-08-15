# frozen_string_literal: true

require "spec_helper"

describe Stripe::SetupIntentsController, :vcr do
  let!(:merchant_account) do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id)
  end

  describe "POST create" do
    context "when card params are invalid" do
      it "responds with an error" do
        post :create, params: {}

        expect(response).to be_unprocessable
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error_message"]).to eq("We couldn't charge your card. Try again or use a different card.")
      end

      it "does not log buyer contact or billing data", vcr: false do
        allow(CardParamsHelper).to receive(:check_for_errors).and_return(nil)
        allow(CardParamsHelper).to receive(:build_chargeable).and_return(nil)
        expect(controller.logger).to receive(:error).with("Error while creating setup intent: failed to load chargeable")

        post :create, params: {
          stripe_payment_method_id: "pm_test",
          email: "buyer@example.com",
          billing_info: { country: "US", state: "CA", postal_code: "94107" },
        }
      end
    end

    context "when card handling error occurred" do
      it "responds with an error" do
        post :create, params: StripePaymentMethodHelper.decline.to_stripejs_params

        expect(response).to be_unprocessable
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error_message"]).to eq("Your card was declined.")
      end
    end

    it "rejects an unauthenticated subscription mandate request before creating Stripe objects" do
      subscription = create(:subscription)
      expect(CardParamsHelper).not_to receive(:build_chargeable)

      post :create, params: { products: [{ subscription_id: subscription.external_id }] }

      expect(response).to be_not_found
      expect(response.parsed_body["success"]).to eq(false)
    end

    context "when card params are valid" do
      let(:card_with_sca) { StripePaymentMethodHelper.success_indian_card_mandate }

      it "skips SetupIntent creation for a new flagged registration", vcr: false do
        product = create(:subscription_product)
        Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, product.user)
        chargeable = double(prepare!: nil, reusable_token_for!: "cus_test")
        allow(CardParamsHelper).to receive(:check_for_errors).and_return(nil)
        allow(CardParamsHelper).to receive(:build_chargeable).and_return(chargeable)
        expect(ChargeProcessor).not_to receive(:setup_future_charges!)

        post :create, params: {
          mandate_reliability_setup: true,
          products: [{ price: product.price_cents, permalink: product.unique_permalink, force_new_subscription: true }]
        }

        expect(response).to be_successful
        expect(response.parsed_body).to include(
          "success" => true,
          "reusable_token" => "cus_test",
          "setup_intent_skipped" => true
        )
        expect(response.parsed_body).not_to have_key("setup_intent_id")
      ensure
        Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, product.user) if product
      end

      it "creates a Stripe customer and sets up future usage" do
        expect(Stripe::Customer).to receive(:create).with(hash_including(payment_method: card_with_sca.to_stripejs_payment_method_id)).and_call_original
        expect(ChargeProcessor).to receive(:setup_future_charges!).with(anything, anything, mandate_options: {
                                                                          payment_method_options: {
                                                                            card: {
                                                                              mandate_options: hash_including({
                                                                                                                amount_type: "maximum",
                                                                                                                amount: 10_00,
                                                                                                                currency: "usd",
                                                                                                                interval: "sporadic",
                                                                                                                supported_types: ["india"]
                                                                                                              })
                                                                            }
                                                                          }
                                                                        }).and_call_original

        post :create, params: card_with_sca.to_stripejs_params.merge!(products: [{ price: 10_00 }, { price: 5_00 }, { price: 7_00 }])
      end

      it "uses server-owned subscription terms for a subscription mandate" do
        subscription = create(:subscription)
        chargeable = double(requires_mandate?: true)
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(products: [{ price: 1, subscription_id: subscription.external_id }]))
        allow(subscription).to receive(:india_card_mandate_reliability_enabled?).and_return(true)
        expect(subscription).to receive(:indian_card_mandate_terms).with(billing_info: nil).and_return(
          amount: 12_34,
          currency: Currency::INR,
          interval: "month",
          interval_count: 3
        )

        mandate_options = controller.send(:mandate_options_for_stripe, chargeable, subscription:)
        mandate_terms = mandate_options.dig(:payment_method_options, :card, :mandate_options)

        expect(mandate_options[:metadata]).to eq(gumroad_subscription_id: subscription.external_id)
        expect(mandate_terms).to include(
          amount: 12_34,
          currency: Currency::INR,
          interval: "month",
          interval_count: 3,
          reference: StripeChargeProcessor::MANDATE_PREFIX + subscription.external_id
        )
      end

      it "omits the interval count for a sporadic subscription mandate" do
        subscription = create(:subscription)
        chargeable = double(requires_mandate?: true)
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(products: [{ subscription_id: subscription.external_id }]))
        allow(subscription).to receive(:india_card_mandate_reliability_enabled?).and_return(true)
        allow(subscription).to receive(:indian_card_mandate_terms).and_return(
          amount: 12_34,
          currency: Currency::USD,
          interval: "sporadic",
          interval_count: nil
        )

        mandate_terms = controller.send(:mandate_options_for_stripe, chargeable, subscription:)
          .dig(:payment_method_options, :card, :mandate_options)

        expect(mandate_terms).to include(interval: "sporadic")
        expect(mandate_terms).not_to have_key(:interval_count)
      end

      it "uses the submitted billing location for subscription mandate terms" do
        subscription = create(:subscription)
        chargeable = double(requires_mandate?: true)
        billing_info = { "country" => "US", "state" => "CA", "postal_code" => "94107" }
        allow(controller).to receive(:params).and_return(
          ActionController::Parameters.new(
            billing_info:,
            products: [{ subscription_id: subscription.external_id }]
          )
        )
        allow(subscription).to receive(:india_card_mandate_reliability_enabled?).and_return(true)
        expect(subscription).to receive(:indian_card_mandate_terms).with(billing_info:).and_return(
          amount: 12_34,
          currency: Currency::INR,
          interval: "month",
          interval_count: 1
        )

        controller.send(:mandate_options_for_stripe, chargeable, subscription:)
      end

      it "uses a cookie-authenticated checkout subscription for server-owned mandate terms" do
        product = create(:subscription_product)
        subscription = create(:subscription, link: product)
        allow(controller).to receive(:params).and_return(
          ActionController::Parameters.new(
            email: "buyer@example.com",
            products: [{ price: product.price_cents, permalink: product.unique_permalink }]
          )
        )
        allow(Subscription).to receive(:restartable_for_product_and_email)
          .with(product:, email: "buyer@example.com")
          .and_return(subscription)
        allow(subscription).to receive(:india_card_mandate_reliability_enabled?).and_return(true)
        encrypted_cookies = double
        allow(encrypted_cookies).to receive(:[]).with(subscription.cookie_key).and_return(subscription.external_id)
        allow(controller).to receive(:cookies).and_return(double(encrypted: encrypted_cookies))

        expect(controller.send(:authenticated_subscription)).to eq(subscription)
      end

      it "uses the same email-derived restart as checkout without its cookie" do
        product = create(:subscription_product)
        subscription = create(:subscription, link: product)
        allow(controller).to receive(:params).and_return(
          ActionController::Parameters.new(
            email: "buyer@example.com",
            products: [{ price: product.price_cents, permalink: product.unique_permalink }]
          )
        )
        allow(Subscription).to receive(:restartable_for_product_and_email)
          .with(product:, email: "buyer@example.com")
          .and_return(subscription)

        allow(subscription).to receive(:india_card_mandate_reliability_enabled?).and_return(true)

        expect(controller.send(:authenticated_subscription)).to eq(subscription)
      end

      it "does not bind one setup intent to multiple recurring products" do
        products = create_list(:subscription_product, 2)
        allow(controller).to receive(:params).and_return(
          ActionController::Parameters.new(
            email: "buyer@example.com",
            products: products.map { { price: _1.price_cents, permalink: _1.unique_permalink } }
          )
        )
        expect(Subscription).not_to receive(:restartable_for_product_and_email)

        expect(controller.send(:authenticated_subscription)).to be_nil
      end

      it "does not bind a forced new subscription to an old subscription" do
        product = create(:subscription_product)
        allow(controller).to receive(:params).and_return(
          ActionController::Parameters.new(
            email: "buyer@example.com",
            products: [{ price: product.price_cents, permalink: product.unique_permalink, force_new_subscription: true }]
          )
        )
        expect(Subscription).not_to receive(:restartable_for_product_and_email)

        expect(controller.send(:authenticated_subscription)).to be_nil
      end

      it "does not bind a mixed restart and forced-new recurring cart" do
        restart_product, new_product = create_list(:subscription_product, 2)
        allow(controller).to receive(:params).and_return(
          ActionController::Parameters.new(
            email: "buyer@example.com",
            products: [
              { price: restart_product.price_cents, permalink: restart_product.unique_permalink },
              { price: new_product.price_cents, permalink: new_product.unique_permalink, force_new_subscription: true }
            ]
          )
        )
        expect(Subscription).not_to receive(:restartable_for_product_and_email)

        expect(controller.send(:authenticated_subscription)).to be_nil
      end

      it "does not bind a restart setup intent when a preorder also needs future authorization" do
        restart_product = create(:subscription_product)
        preorder_product = create(:product, is_in_preorder_state: true)
        allow(controller).to receive(:params).and_return(
          ActionController::Parameters.new(
            email: "buyer@example.com",
            products: [
              { price: restart_product.price_cents, permalink: restart_product.unique_permalink },
              { price: preorder_product.price_cents, permalink: preorder_product.unique_permalink }
            ]
          )
        )
        expect(Subscription).not_to receive(:restartable_for_product_and_email)

        expect(controller.send(:authenticated_subscription)).to be_nil
      end

      context "when setup intent succeeds" do
        it "renders a successful response" do
          post :create, params: StripePaymentMethodHelper.success_with_sca.to_stripejs_params

          expect(response).to be_successful
          expect(response.parsed_body["success"]).to eq(true)
          expect(response.parsed_body["reusable_token"]).to be_present
          expect(response.parsed_body["setup_intent_id"]).to be_present
        end
      end

      context "when setup intent requires action" do
        it "renders a successful response" do
          post :create, params: StripePaymentMethodHelper.success_with_sca.to_stripejs_params

          expect(response).to be_successful
          expect(response.parsed_body["success"]).to eq(true)
          expect(response.parsed_body["requires_card_setup"]).to eq(true)
          expect(response.parsed_body["reusable_token"]).to be_present
          expect(response.parsed_body["client_secret"]).to be_present
          expect(response.parsed_body["setup_intent_id"]).to be_present
        end
      end

      context "when charge processor error occurs" do
        before do
          allow(ChargeProcessor).to receive(:setup_future_charges!).and_raise(ChargeProcessorUnavailableError)
        end

        it "responds with an error" do
          post :create, params: StripePaymentMethodHelper.success_with_sca.to_stripejs_params

          expect(response).to be_server_error
          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["error_message"]).to eq("There is a temporary problem, please try again (your card was not charged).")
        end
      end
    end
  end
end
