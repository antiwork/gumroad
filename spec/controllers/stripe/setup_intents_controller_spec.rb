# frozen_string_literal: true

require "spec_helper"

describe Stripe::SetupIntentsController, :vcr do
  let!(:merchant_account) do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id)
  end

  describe "#three_d_secure_seller" do
    it "returns the seller of the products on the request when the flag is on for that seller" do
      flagged_seller = create(:user)
      unflagged_seller = create(:user)
      flagged_product = create(:product, user: flagged_seller)
      unflagged_product = create(:product, user: unflagged_seller)
      allow(controller).to receive(:product_params_list).and_return(
        [{ "permalink" => unflagged_product.unique_permalink }, { "permalink" => flagged_product.unique_permalink }]
      )
      Feature.activate_user(:card_3ds_challenge, flagged_seller)

      expect(controller.send(:three_d_secure_seller)).to eq(flagged_seller)
    ensure
      Feature.deactivate_user(:card_3ds_challenge, flagged_seller) if flagged_seller
    end

    it "returns nothing when no seller on the request is in the cohort" do
      product = create(:product)

      allow(controller).to receive(:product_params_list).and_return([{ "permalink" => product.unique_permalink }])

      expect(controller.send(:three_d_secure_seller)).to be_nil
    end
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
                                                                        }, seller: nil).and_call_original

        post :create, params: card_with_sca.to_stripejs_params.merge!(products: [{ price: 10_00 }, { price: 5_00 }, { price: 7_00 }])
      end

      context "when the cart holds a product whose seller is in the 3DS cohort", vcr: false do
        let(:chargeable) { double(prepare!: nil, reusable_token_for!: "cus_test", requires_mandate?: false) }
        let(:flagged_seller) { create(:user) }

        before do
          allow(CardParamsHelper).to receive(:check_for_errors).and_return(nil)
          allow(CardParamsHelper).to receive(:build_chargeable).and_return(chargeable)
          Feature.activate_user(:card_3ds_challenge, flagged_seller)
        end

        after { Feature.deactivate_user(:card_3ds_challenge, flagged_seller) }

        def post_and_capture_card_setup(*products)
          captured = nil
          allow(ChargeProcessor).to receive(:setup_future_charges!) do |account, card, **kwargs|
            captured = { account:, card:, **kwargs }
            instance_double(StripeSetupIntent, id: "seti_3ds", succeeded?: true)
          end

          post :create, params: {
            stripe_payment_method_id: "pm_test",
            products: products.map { { price: _1.price_cents, permalink: _1.unique_permalink } }
          }

          captured
        end

        it "sets the card up for that seller on the shared Gumroad account" do
          captured = post_and_capture_card_setup(create(:product, user: flagged_seller))

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body).to eq("success" => true, "reusable_token" => "cus_test", "setup_intent_id" => "seti_3ds")
          expect(captured).to include(account: merchant_account, card: chargeable, mandate_options: nil, seller: flagged_seller)
        end

        it "sets the card up for the flagged seller when an unflagged seller's product comes first" do
          captured = post_and_capture_card_setup(create(:product), create(:product, user: flagged_seller))

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body).to include("success" => true, "setup_intent_id" => "seti_3ds")
          expect(captured[:seller]).to eq(flagged_seller)
        end
      end

      it "uses server-owned subscription terms for a subscription mandate" do
        subscription = create(:subscription)
        chargeable = double(requires_mandate?: true)
        allow(Rails.env).to receive(:production?).and_return(true)
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(products: [{ price: 1, subscription_id: subscription.external_id }]))
        allow(subscription).to receive(:india_card_mandate_reliability_enabled?).and_return(true)
        expect(subscription).to receive(:indian_card_mandate_terms_with_rate).twice.with(
          billing_info: nil,
          authenticated_offer_code_buyer: nil,
          renewal_price_cents: nil
        ).and_return(
          [
            {
              amount: 12_34,
              currency: Currency::INR,
              interval: "month",
              interval_count: 3
            },
            "80.0"
          ]
        )

        mandate_options = controller.send(:mandate_options_for_stripe, chargeable, subscription:)
        next_mandate_options = controller.send(:mandate_options_for_stripe, chargeable, subscription:)
        mandate_terms = mandate_options.dig(:payment_method_options, :card, :mandate_options)
        next_mandate_terms = next_mandate_options.dig(:payment_method_options, :card, :mandate_options)

        expect(mandate_options[:metadata]).to eq(
          gumroad_subscription_id: subscription.external_id,
          gumroad_mandate_rate: "80.0"
        )
        expect(mandate_terms).to include(
          amount: 12_34,
          currency: Currency::INR,
          interval: "month",
          interval_count: 3
        )
        expect(mandate_terms[:reference]).to start_with("#{StripeChargeProcessor::MANDATE_PREFIX}#{subscription.external_id}-")
        expect(next_mandate_terms[:reference]).not_to eq(mandate_terms[:reference])
      end

      it "sizes a manage-page mandate for the paid next charge while an ownership-tiered code makes this period free" do
        purchase = create(:membership_purchase, created_at: Time.current, link: create(:membership_product, subscription_duration: :yearly))
        subscription = purchase.subscription
        offer_code = create(:tiered_offer_code, user: purchase.link.user, products: [purchase.link],
                                                ownership_duration_tiers: [{ "months" => 0, "amount_percentage" => 100 }, { "months" => 12, "amount_percentage" => 0 }])
        purchase.update!(offer_code:, displayed_price_cents: 0)
        purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: true,
                                                      pre_discount_minimum_price_cents: 5_00)
        subscription.reload
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(products: [{ subscription_id: subscription.external_id, price: 0 }]))
        expect(subscription.current_subscription_price_cents).to eq(0)

        mandate_options = controller.send(:mandate_options_for_stripe, double(requires_mandate?: true), subscription:)

        expect(mandate_options.dig(:payment_method_options, :card, :mandate_options)).to include(amount: 5_00, amount_type: "maximum")
      end

      it "omits the interval count for a sporadic subscription mandate" do
        subscription = create(:subscription)
        chargeable = double(requires_mandate?: true)
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(products: [{ subscription_id: subscription.external_id }]))
        allow(subscription).to receive(:india_card_mandate_reliability_enabled?).and_return(true)
        allow(subscription).to receive(:indian_card_mandate_terms_with_rate).and_return(
          [
            {
              amount: 12_34,
              currency: Currency::USD,
              interval: "sporadic",
              interval_count: nil
            },
            nil
          ]
        )

        mandate_options = controller.send(:mandate_options_for_stripe, chargeable, subscription:)
        mandate_terms = mandate_options.dig(:payment_method_options, :card, :mandate_options)

        expect(mandate_terms).to include(interval: "sporadic")
        expect(mandate_terms).not_to have_key(:interval_count)
        expect(mandate_options[:metadata]).to eq(gumroad_subscription_id: subscription.external_id)
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
        expect(subscription).to receive(:indian_card_mandate_terms_with_rate).with(
          billing_info:,
          authenticated_offer_code_buyer: nil,
          renewal_price_cents: nil
        ).and_return(
          [
            {
              amount: 12_34,
              currency: Currency::INR,
              interval: "month",
              interval_count: 1
            },
            "80.0"
          ]
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

      context "when a membership is storing a card whose Indian mandate is pending or active", vcr: false do
        let(:buyer) { create(:user) }
        let(:product) { create(:subscription_product) }
        let(:subscription) { create(:subscription, link: product, user: buyer, credit_card: stored_card) }
        let(:chargeable) { double(prepare!: nil, reusable_token_for!: "cus_new", requires_mandate?: false, fingerprint: "fingerprint_pending") }
        let(:stored_card) do
          create(:indian_stripe_credit_card, stripe_setup_intent_id: "seti_pending")
        end
        let(:stored_ids) { %w[cus_pending seti_pending pm_pending] }
        let(:billing_info) { { country: "IN", state: "MH", postal_code: "400001" } }
        let(:manage_params) do
          {
            stripe_payment_method_id: "pm_unused",
            billing_info:,
            products: [{ price: product.price_cents, permalink: product.unique_permalink, subscription_id: subscription.external_id }]
          }
        end
        let(:guest_params) do
          {
            stripe_payment_method_id: "pm_unused",
            email: "buyer@example.com",
            billing_info:,
            products: [{ price: product.price_cents, permalink: product.unique_permalink }]
          }
        end
        let(:new_setup_intent) { instance_double(StripeSetupIntent, id: "seti_new", succeeded?: true) }

        before do
          allow(subscription).to receive(:india_card_mandate_reliability_enabled?).and_return(true)
          allow(Subscription).to receive(:find_by_external_id).with(subscription.external_id).and_return(subscription)
          allow(Subscription).to receive(:restartable_for_product_and_email).with(product:, email: "buyer@example.com").and_return(subscription)
          allow(subscription).to receive(:reusable_pending_indian_card).and_return(stored_card)
          allow(CardParamsHelper).to receive(:check_for_errors).and_return(nil)
          allow(CardParamsHelper).to receive(:build_chargeable).and_return(chargeable)
        end

        def expect_stored_card_returned
          expect(response).to be_successful
          expect(response.parsed_body).to eq(
            "success" => true,
            "reusable_token" => "cus_pending",
            "setup_intent_id" => "seti_pending",
            "payment_method_id" => "pm_pending"
          )
        end

        def expect_stored_card_not_exposed
          expect(subscription).not_to have_received(:reusable_pending_indian_card)
          stored_ids.each { expect(response.body).not_to include(_1) }
        end

        context "with the subscription's manage cookie" do
          before { request.cookie_jar.encrypted[subscription.cookie_key] = subscription.external_id }

          it "returns the stored setup intent, customer, and payment method instead of creating another" do
            expect(ChargeProcessor).not_to receive(:setup_future_charges!)

            post :create, params: manage_params

            expect_stored_card_returned
            expect(subscription).to have_received(:reusable_pending_indian_card).with(
              billing_info: { "country" => "IN", "state" => "MH", "postal_code" => "400001" },
              authenticated_offer_code_buyer: nil
            )
          end

          it "creates a new setup intent and remembers it in the session when the stored one is no longer reusable" do
            allow(subscription).to receive(:reusable_pending_indian_card).and_return(nil)
            expect(ChargeProcessor).to receive(:setup_future_charges!).and_return(new_setup_intent)

            post :create, params: manage_params

            expect(response.parsed_body).to include("setup_intent_id" => "seti_new", "reusable_token" => "cus_new")
            expect(response.parsed_body).not_to have_key("payment_method_id")
            expect(session[described_class::SESSION_SETUP_INTENT_KEY]).to eq([[subscription.external_id, "seti_new"]])
          end

          it "creates a new setup intent without asking Stripe when the buyer submits a different card" do
            allow(chargeable).to receive(:fingerprint).and_return("fingerprint_other")
            expect(ChargeProcessor).to receive(:setup_future_charges!).and_return(new_setup_intent)

            post :create, params: manage_params

            expect(response.parsed_body).to include("setup_intent_id" => "seti_new")
            expect(subscription).not_to have_received(:reusable_pending_indian_card)
          end
        end

        context "when a guest restarts by email and product permalink" do
          it "does not return the stored card's Stripe ids to a caller with no cookie, session, or login" do
            expect(ChargeProcessor).to receive(:setup_future_charges!).and_return(new_setup_intent)

            post :create, params: guest_params

            expect(response.parsed_body).to include("setup_intent_id" => "seti_new", "reusable_token" => "cus_new")
            expect_stored_card_not_exposed
          end

          it "does not return the stored card to a session that minted a different setup intent" do
            session[described_class::SESSION_SETUP_INTENT_KEY] = [[subscription.external_id, "seti_other"]]
            expect(ChargeProcessor).to receive(:setup_future_charges!).and_return(new_setup_intent)

            post :create, params: guest_params

            expect_stored_card_not_exposed
          end

          it "does not return the stored card to a session that minted the setup intent for another subscription" do
            session[described_class::SESSION_SETUP_INTENT_KEY] = [["other_subscription", "seti_pending"]]
            expect(ChargeProcessor).to receive(:setup_future_charges!).and_return(new_setup_intent)

            post :create, params: guest_params

            expect_stored_card_not_exposed
          end

          it "returns the stored card to the session that minted its setup intent" do
            session[described_class::SESSION_SETUP_INTENT_KEY] = [[subscription.external_id, "seti_pending"]]
            expect(ChargeProcessor).not_to receive(:setup_future_charges!)

            post :create, params: guest_params

            expect_stored_card_returned
          end

          it "keeps the earlier setup intents when another one is minted for a different card" do
            session[described_class::SESSION_SETUP_INTENT_KEY] = [[subscription.external_id, "seti_pending"]]
            allow(chargeable).to receive(:fingerprint).and_return("fingerprint_other")
            expect(ChargeProcessor).to receive(:setup_future_charges!).and_return(new_setup_intent)

            post :create, params: guest_params

            expect(session[described_class::SESSION_SETUP_INTENT_KEY]).to eq([[subscription.external_id, "seti_pending"], [subscription.external_id, "seti_new"]])
          end

          it "remembers only the newest setup intents once the session list is full" do
            session[described_class::SESSION_SETUP_INTENT_KEY] = Array.new(described_class::MAX_SESSION_SETUP_INTENTS) { [subscription.external_id, "seti_old_#{_1}"] }
            expect(ChargeProcessor).to receive(:setup_future_charges!).and_return(new_setup_intent)

            post :create, params: guest_params

            remembered = session[described_class::SESSION_SETUP_INTENT_KEY]
            expect(remembered.size).to eq(described_class::MAX_SESSION_SETUP_INTENTS)
            expect(remembered.first).to eq([subscription.external_id, "seti_old_1"])
            expect(remembered.last).to eq([subscription.external_id, "seti_new"])
          end

          it "returns the stored card to the signed-in owner" do
            sign_in buyer
            allow(Subscription).to receive(:restartable_for_product_and_buyer).with(product:, buyer:).and_return(subscription)
            expect(ChargeProcessor).not_to receive(:setup_future_charges!)

            post :create, params: guest_params

            expect_stored_card_returned
          end

          it "does not return the stored card to a different signed-in user" do
            other_user = create(:user)
            sign_in other_user
            allow(Subscription).to receive(:restartable_for_product_and_buyer).with(product:, buyer: other_user).and_return(subscription)
            expect(ChargeProcessor).to receive(:setup_future_charges!).and_return(new_setup_intent)

            post :create, params: guest_params

            expect_stored_card_not_exposed
          end
        end
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

  describe "sizing a membership's replacement Indian card mandate for the real updater",
           vcr: { cassette_name: "Stripe_SetupIntentsController/restarting_an_ended_membership_after_the_seller_raised_the_tier_price", record: :none, allow_playback_repeats: true } do
    include ManageSubscriptionHelpers

    let(:merchant_account) do
      create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: nil)
    end
    let(:replacement_card) do
      create(:indian_stripe_credit_card, stripe_customer_id: "cus_replacement", processor_payment_method_id: "pm_replacement",
                                         stripe_fingerprint: "fingerprint_replacement", stripe_setup_intent_id: "seti_replacement")
    end

    before do
      allow(MerchantAccount).to receive(:gumroad).with(StripeChargeProcessor.charge_processor_id).and_return(merchant_account)
      allow_any_instance_of(Subscription).to receive(:send_restart_notifications!)
    end

    def end_membership_and_raise_tier_price_to(new_price_cents)
      Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @product.user)
      @subscription.update!(cancelled_at: @originally_subscribed_at + 3.months, cancelled_by_buyer: true, deactivated_at: @originally_subscribed_at + 3.months)
      travel_to(@originally_subscribed_at + 4.months)
      @original_tier_quarterly_price.update!(price_cents: new_price_cents)
    end

    # Mints the mandate with this controller, then restarts through the real updater with a SetupIntent carrying exactly those terms.
    def restart_with_controller_mandate(new_price_cents)
      allow(controller).to receive(:params).and_return(ActionController::Parameters.new(products: [{ subscription_id: @subscription.external_id }]))
      allow(controller).to receive(:logged_in_user).and_return(@user)
      options = controller.send(:mandate_options_for_stripe, double(requires_mandate?: true), subscription: Subscription.find(@subscription.id))

      update_with_setup_intent_options(
        options,
        price_id: @quarterly_product_price.external_id,
        variants: [@original_tier.external_id],
        quantity: 1,
        perceived_price_cents: new_price_cents,
        perceived_upgrade_price_cents: new_price_cents,
      )
    end

    def mint_setup_intent_for_plan(plan, billing_info:)
      allow(controller).to receive(:logged_in_user).and_return(@user)
      allow(CardParamsHelper).to receive(:check_for_errors).and_return(nil)
      allow(CardParamsHelper).to receive(:build_chargeable).and_return(
        double(prepare!: nil, reusable_token_for!: "cus_replacement", requires_mandate?: true, fingerprint: "fingerprint_replacement")
      )
      options = nil
      allow(ChargeProcessor).to receive(:setup_future_charges!) do |_merchant_account, _chargeable, mandate_options:, **_rest|
        options = mandate_options
        instance_double(StripeSetupIntent, id: "seti_replacement", succeeded?: true)
      end
      request.cookie_jar.encrypted[@subscription.cookie_key] = @subscription.external_id

      post :create, params: {
        stripe_payment_method_id: "pm_replacement",
        billing_info:,
        products: [{ price: plan[:perceived_upgrade_price_cents], subscription_id: @subscription.external_id, **plan.except(:perceived_upgrade_price_cents) }]
      }

      options
    end

    def change_plan_with_controller_mandate(billing_info: { country: "FR", state: nil, postal_code: nil }, **plan)
      options = mint_setup_intent_for_plan(plan, billing_info:)
      expect(response).to be_successful

      update_with_setup_intent_options(options, **plan, contact_info: { country: billing_info[:country], zip_code: billing_info[:postal_code] })
    end

    def update_with_setup_intent_options(options, **params)
      mandate_options = options.dig(:payment_method_options, :card, :mandate_options)
      allow(ChargeProcessor).to receive(:get_setup_intent).and_return(
        instance_double(
          StripeSetupIntent, succeeded?: true, mandate: "mandate_active", payment_method_id: "pm_replacement",
                             customer_id: "cus_replacement", usage: "off_session", metadata: options[:metadata].transform_values(&:to_s),
                             card_mandate_options: Stripe::StripeObject.construct_from(mandate_options.except(:start_date))
        )
      )
      allow(ChargeProcessor).to receive(:get_mandate).and_return(Stripe::Mandate.construct_from(id: "mandate_active", status: "active", payment_method: "pm_replacement"))
      allow(CreditCard).to receive(:create).and_return(replacement_card)
      service = Subscription::UpdaterService.new(
        subscription: Subscription.find(@subscription.id),
        gumroad_guid: "guid",
        params:,
        logged_in_user: @user,
        remote_ip: "11.22.33.44"
      )
      stripe_chargeable = StripeChargeablePaymentMethod.new("pm_replacement", zip_code: "12345", product_permalink: @product.unique_permalink)
      allow(service).to receive(:get_chargeable) { service.chargeable = instance_double(Chargeable, get_chargeable_for: stripe_chargeable); nil }
      allow(service).to receive(:charge_user!).and_return(success: true)

      [mandate_options, service.perform, service]
    end

    def schedule_deferred_downgrade(perceived_price_cents: 4_00, billing_info: { country: "FR", state: nil, postal_code: nil })
      travel_to(@originally_subscribed_at + 1.month)
      change_plan_with_controller_mandate(
        billing_info:,
        price_id: @quarterly_product_price.external_id,
        variants: [@lower_tier.external_id],
        quantity: 1,
        perceived_price_cents:,
        perceived_upgrade_price_cents: 0,
      )
    end

    def restub_setup_intent(**overrides)
      current = ChargeProcessor.get_setup_intent(nil, nil)
      attributes = %i[succeeded? mandate payment_method_id customer_id usage metadata card_mandate_options].index_with { current.public_send(_1) }
      allow(ChargeProcessor).to receive(:get_setup_intent).and_return(instance_double(StripeSetupIntent, **attributes, **overrides))
    end

    def renew_at_period_end(runs: 1)
      processor_charges = []
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |_account, _chargeable, amount_cents, *_rest, **options|
        processor_charges << options.merge(amount_cents:)
        ChargeIntent.new.tap do |intent|
          intent.id = "pi_renewal_#{processor_charges.size}"
          intent.charge = BaseProcessorCharge.new.tap do |charge|
            charge.charge_processor_id = StripeChargeProcessor.charge_processor_id
            charge.id = "ch_renewal_#{processor_charges.size}"
            charge.status = "succeeded"
            charge.refunded = false
            charge.fee = 0
            charge.fee_currency = Currency::USD
            charge.card_fingerprint = "fingerprint_replacement"
            charge.card_expiry_month = 12
            charge.card_expiry_year = 2030
          end
        end
      end
      allow(CustomerLowPriorityMailer).to receive(:subscription_indian_card_mandate_invalid).and_call_original
      travel_to(@subscription.reload.end_time_of_subscription + 1.minute)
      runs.times { RecurringChargeWorker.new.perform(@subscription.id) }
      processor_charges
    end

    def renewal_charges
      @subscription.reload.purchases.successful.not_is_original_subscription_purchase.where("purchases.created_at > ?", @originally_subscribed_at + 1.day).order(:id).to_a
    end

    it "accepts a mandate sized for the raised price plus tax" do
      setup_subscription_with_vat
      end_membership_and_raise_tier_price_to(@original_tier_quarterly_price.price_cents + 24_00)

      mandate_options, result = restart_with_controller_mandate(@original_tier_quarterly_price.price_cents)

      expect(mandate_options).to include(amount: 35_99)
      expect(result).to include(success: true)
    end

    it "leaves tax off the mandate when the VAT ID that exempts the restart is only on the original purchase" do
      allow_any_instance_of(VatValidationService).to receive(:process).and_return(true)
      setup_subscription_with_vat(vat_id: "FR123456789")
      @subscription.update_column(:business_vat_id, nil)
      end_membership_and_raise_tier_price_to(@original_tier_quarterly_price.price_cents + 24_00)

      mandate_options, result = restart_with_controller_mandate(@original_tier_quarterly_price.price_cents)

      expect(mandate_options).to include(amount: 29_99)
      expect(result).to include(success: true)
    end

    it "sizes the mandate as the free-trial re-check does when the VAT ID is only on a free-trial original purchase" do
      allow_any_instance_of(VatValidationService).to receive(:process).and_return(true)
      setup_subscription_with_vat(vat_id: "FR123456789")
      @original_purchase.update!(is_free_trial_purchase: true)
      @subscription.update_columns(business_vat_id: nil, free_trial_ends_at: @originally_subscribed_at + 1.week)
      end_membership_and_raise_tier_price_to(@original_tier_quarterly_price.price_cents + 24_00)

      mandate_options, result = restart_with_controller_mandate(@original_tier_quarterly_price.price_cents)

      expect(mandate_options).to include(amount: 35_99)
      expect(result).to include(success: true)
    end

    it "accepts a rupee mandate sized at today's rate when the rate moved since signup" do
      setup_subscription
      @product.update_column(:price_currency_type, Currency::INR)
      @subscription.original_purchase.update_columns(displayed_price_currency_type: Currency::INR, displayed_price_cents: 80_000,
                                                     price_cents: 8_00, total_transaction_cents: 8_00, rate_converted_to_usd: "100")
      Redis::Namespace.new(:currencies, redis: $redis).set("INR", "80")
      end_membership_and_raise_tier_price_to(160_000)

      mandate_options, result = restart_with_controller_mandate(160_000)

      expect(mandate_options).to include(amount: 160_000)
      expect(result).to include(success: true)
    end

    it "sizes a dollar mandate when the restart price outdates a stored rupee fixing" do
      setup_subscription
      Redis::Namespace.new(:currencies, redis: $redis).set("INR", "80")
      old_price_cents = @original_tier_quarterly_price.price_cents
      create(:later_charge_presentment, owner: @subscription, presentment_currency: Currency::INR, presentment_price_cents: old_price_cents * 80,
                                        canonical_price_cents: old_price_cents, signup_currency_units_per_usd: 80, effective_from: @originally_subscribed_at)
      end_membership_and_raise_tier_price_to(old_price_cents + 24_00)

      mandate_options, result = restart_with_controller_mandate(@original_tier_quarterly_price.price_cents)

      expect(mandate_options).to include(amount: 29_99, currency: Currency::USD)
      expect(result).to include(success: true)
    end

    context "when an INR-listed membership schedules a downgrade with a new Indian card" do
      before do
        setup_subscription
        Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @product.user)
        @product.update_column(:price_currency_type, Currency::INR)
        @original_tier_quarterly_price.update!(price_cents: 80_000)
        @lower_tier_quarterly_price.update!(price_cents: 40_000)
        @subscription.original_purchase.update_columns(displayed_price_currency_type: Currency::INR, displayed_price_cents: 80_000,
                                                       price_cents: 10_00, total_transaction_cents: 10_00, rate_converted_to_usd: "80")
        Redis::Namespace.new(:currencies, redis: $redis).set("INR", "80")
        create(:later_charge_presentment, owner: @subscription, presentment_currency: Currency::INR, presentment_price_cents: 80_000,
                                          canonical_price_cents: 10_00, signup_currency_units_per_usd: 80, effective_from: @originally_subscribed_at)
        @subscription.reload
      end

      it "renews in rupees on the fixing recorded with the mandate approved for the scheduled tier" do
        mandate_options, result = schedule_deferred_downgrade(perceived_price_cents: 40_000, billing_info: { country: "IN", state: nil, postal_code: nil })

        expect(result).to include(success: true)
        expect(mandate_options).to include(amount: 40_000, currency: Currency::INR, interval: "month", interval_count: 3)
        expect(@subscription.reload.current_later_charge_presentment).to have_attributes(presentment_price_cents: 40_000, canonical_price_cents: 5_00)
        expect(@subscription.tier).to eq(@original_tier)

        allow(StripeFxQuote).to receive(:create).and_return(double(id: "fxq_renewal", fx_rate: BigDecimal(1) / 80, expires_at: 1.day.from_now))
        processor_charges = renew_at_period_end(runs: 2)

        @subscription.reload
        expect(@subscription).not_to be_indian_card_mandate_requires_reauthorization
        expect(@subscription.stripe_mandate_id).to eq("mandate_active")
        expect(@subscription.tier).to eq(@lower_tier)
        expect(@subscription.indian_card_presentment_in_force?(@subscription.current_later_charge_presentment)).to be(true)
        expect(@subscription.indian_card_mandate_terms).to eq(mandate_options.slice(:amount, :currency, :interval, :interval_count))
        expect(processor_charges.sole).to include(processor_currency: Currency::INR, processor_amount_cents: mandate_options[:amount], mandate_expected: true)
        renewal = @subscription.purchases.not_is_original_subscription_purchase.where(created_at: Time.current.all_day).sole
        expect(renewal).to have_attributes(purchase_state: "in_progress", displayed_price_currency_type: Currency::INR.to_sym, displayed_price_cents: 40_000)
        expect(FinalizeBuyerPresentmentPurchaseJob.jobs.map { _1["args"] }).to eq([[renewal.id]])
      end
    end

    context "when the buyer selects another plan" do
      before do
        setup_subscription_with_vat
        Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @product.user)
      end

      def end_membership
        @subscription.update!(cancelled_at: @originally_subscribed_at + 3.months, cancelled_by_buyer: true, deactivated_at: @originally_subscribed_at + 3.months)
        travel_to(@originally_subscribed_at + 4.months)
      end

      it "sizes a restart mandate for the selected tier plus tax" do
        end_membership

        mandate_options, result = change_plan_with_controller_mandate(
          price_id: @quarterly_product_price.external_id,
          variants: [@new_tier.external_id],
          quantity: 1,
          perceived_price_cents: 10_50,
          perceived_upgrade_price_cents: 10_50,
        )

        expect(result).to include(success: true)
        expect(mandate_options).to include(amount: 12_60, currency: Currency::USD, interval: "month", interval_count: 3)
        expect(@subscription.reload.tier).to eq(@new_tier)
      end

      it "sizes a restart mandate for the selected billing period" do
        end_membership

        mandate_options, result = change_plan_with_controller_mandate(
          price_id: @yearly_product_price.external_id,
          variants: [@new_tier.external_id],
          quantity: 1,
          perceived_price_cents: 20_00,
          perceived_upgrade_price_cents: 20_00,
        )

        expect(result).to include(success: true)
        expect(mandate_options).to include(amount: 24_00, interval: "year", interval_count: 1)
      end

      it "sizes a restart mandate for the pay-what-you-want amount the buyer chose" do
        @new_tier.update!(customizable_price: true)
        end_membership

        mandate_options, result = change_plan_with_controller_mandate(
          price_id: @quarterly_product_price.external_id,
          variants: [@new_tier.external_id],
          quantity: 1,
          price_range: 15_00,
          perceived_price_cents: 15_00,
          perceived_upgrade_price_cents: 15_00,
        )

        expect(result).to include(success: true)
        expect(mandate_options).to include(amount: 18_00)
      end

      it "sizes a live upgrade's mandate for the new tier" do
        travel_to(@originally_subscribed_at + 1.month)

        mandate_options, result = change_plan_with_controller_mandate(
          price_id: @quarterly_product_price.external_id,
          variants: [@new_tier.external_id],
          quantity: 1,
          perceived_price_cents: 10_50,
          perceived_upgrade_price_cents: @new_tier_quarterly_upgrade_cost_after_one_month,
        )

        expect(result).to include(success: true)
        expect(mandate_options).to include(amount: 12_60)
        expect(@subscription.reload.tier).to eq(@new_tier)
      end

      it "accepts a deferred downgrade's replacement card with a mandate sized for the scheduled tier" do
        original_price_cents = @subscription.original_purchase.displayed_price_cents
        end_time = @subscription.end_time_of_subscription
        purchase_ids = @subscription.purchases.ids

        mandate_options, result, service = schedule_deferred_downgrade

        expect(result).to include(success: true, success_message: "Your membership will be updated at the end of your current billing cycle.")
        expect(mandate_options).to include(amount: 4_80, currency: Currency::USD, interval: "month", interval_count: 3)
        expect(service).not_to have_received(:charge_user!)
        @subscription.reload
        expect(@subscription.tier).to eq(@original_tier)
        expect(@subscription.original_purchase.displayed_price_cents).to eq(original_price_cents)
        expect(@subscription.end_time_of_subscription).to eq(end_time)
        expect(@subscription.purchases.ids).to match_array(purchase_ids)
        expect(@subscription.credit_card).to eq(replacement_card)
        plan_change = @subscription.subscription_plan_changes.alive.sole
        expect(plan_change).to have_attributes(tier: @lower_tier, recurrence: BasePrice::Recurrence::QUARTERLY, perceived_price_cents: 4_00)

        scheduled_terms = nil
        ActiveRecord::Base.transaction do
          @subscription.update_current_plan!(
            new_variants: [plan_change.tier],
            new_price: @quarterly_product_price,
            new_quantity: plan_change.quantity,
            perceived_price_cents: plan_change.perceived_price_cents,
            is_applying_plan_change: true,
            skip_preparing_for_charge: true,
          )
          scheduled_terms = @subscription.reload.indian_card_mandate_terms
          raise ActiveRecord::Rollback
        end
        expect(scheduled_terms).to eq(mandate_options.slice(:amount, :currency, :interval, :interval_count))
      end

      it "renews a deferred downgrade on the scheduled tier with the mandate approved for it" do
        mandate_options, result = schedule_deferred_downgrade
        expect(result).to include(success: true)

        processor_charges = renew_at_period_end(runs: 2)

        @subscription.reload
        expect(@subscription).not_to be_indian_card_mandate_requires_reauthorization
        expect(@subscription).not_to be_renewal_disabled_due_to_indian_card_mandate
        expect(@subscription.stripe_mandate_id).to eq("mandate_active")
        expect(CustomerLowPriorityMailer).not_to have_received(:subscription_indian_card_mandate_invalid)
        expect(@subscription.tier).to eq(@lower_tier)
        expect(@subscription.subscription_plan_changes.alive).to be_empty
        expect(processor_charges.size).to eq(1)
        expect(processor_charges.first[:amount_cents]).to eq(mandate_options[:amount])
        renewal = renewal_charges.sole
        expect(renewal).to have_attributes(displayed_price_cents: 4_00, total_transaction_cents: 4_80, credit_card_id: replacement_card.id)
        expect(renewal.variant_attributes).to eq([@lower_tier])
      end

      {
        "a mandate approved for the current plan" => -> { restub_setup_intent(card_mandate_options: Stripe::StripeObject.construct_from(ChargeProcessor.get_setup_intent(nil, nil).card_mandate_options.to_hash.merge(amount: 7_19))) },
        "an inactive mandate" => -> { allow(ChargeProcessor).to receive(:get_mandate).and_return(Stripe::Mandate.construct_from(id: "mandate_active", status: "inactive", payment_method: "pm_replacement")) },
        "a SetupIntent minted for another subscription" => -> { restub_setup_intent(metadata: ChargeProcessor.get_setup_intent(nil, nil).metadata.merge(gumroad_subscription_id: "another-subscription")) },
        "a SetupIntent for another payment method" => -> { restub_setup_intent(payment_method_id: "pm_other") },
        "a SetupIntent for another customer" => -> { restub_setup_intent(customer_id: "cus_other") },
        "a SetupIntent that has not succeeded" => -> { restub_setup_intent(succeeded?: false) },
        "a SetupIntent for another mandate" => -> { restub_setup_intent(mandate: "mandate_other") },
        "a SetupIntent Stripe cannot return" => -> { allow(ChargeProcessor).to receive(:get_setup_intent).and_raise(ChargeProcessorUnavailableError) },
      }.each do |stored, restub|
        it "asks for a new mandate instead of renewing a deferred downgrade on #{stored}" do
          _mandate_options, result = schedule_deferred_downgrade
          expect(result).to include(success: true)
          instance_exec(&restub)
          allow(ErrorNotifier).to receive(:notify)

          processor_charges = renew_at_period_end(runs: 2)

          @subscription.reload
          expect(@subscription).to be_indian_card_mandate_requires_reauthorization
          expect(@subscription).to be_renewal_disabled_due_to_indian_card_mandate
          expect(@subscription.stripe_mandate_id).to be_nil
          expect(@subscription.tier).to eq(@lower_tier)
          expect(processor_charges).to be_empty
          expect(renewal_charges).to be_empty
          expect(CustomerLowPriorityMailer).to have_received(:subscription_indian_card_mandate_invalid).with(@subscription.id).once
        end
      end

      it "sizes a restart mandate from the restarted plan when an earlier plan change left another original unarchived" do
        @original_tier_quarterly_price.update!(price_cents: 6_49)
        stale_original = @subscription.update_current_plan!(new_variants: [@original_tier], new_price: @quarterly_product_price, skip_preparing_for_charge: true)
        @original_purchase.update_flag!(:is_archived_original_subscription_purchase, false, true)
        @original_tier_quarterly_price.update!(price_cents: 5_99)
        end_membership
        @subscription.reload
        unarchived_originals = -> { @subscription.reload.purchases.is_original_subscription_purchase.not_is_archived_original_subscription_purchase.order(:id).to_a }
        expect(unarchived_originals.call).to eq([@original_purchase, stale_original])
        plan = { price_id: @quarterly_product_price.external_id, variants: [@new_tier.external_id], quantity: 1, perceived_price_cents: 10_50, perceived_upgrade_price_cents: 10_50 }

        options = mint_setup_intent_for_plan(plan, billing_info: { country: "FR", state: nil, postal_code: nil })

        expect(unarchived_originals.call).to eq([@original_purchase, stale_original])
        mandate_options, result = update_with_setup_intent_options(options, **plan, contact_info: { country: "FR", zip_code: nil })
        expect(result).to include(success: true)
        expect(mandate_options).to include(amount: 12_60)
        expect(unarchived_originals.call).to eq([@subscription.original_purchase])
        expect(@subscription.original_purchase.id).not_to be_in([@original_purchase.id, stale_original.id])
        expect(@subscription.tier).to eq(@new_tier)
      end

      it "reuses a pending card when the buyer restarts on the current plan" do
        end_membership
        subscription = Subscription.find(@subscription.id)
        allow(subscription).to receive(:credit_card).and_return(replacement_card)
        allow(subscription).to receive(:reusable_pending_indian_card).and_return(replacement_card)
        allow(Subscription).to receive(:find_by_external_id).with(@subscription.external_id).and_return(subscription)

        mint_setup_intent_for_plan(
          { price_id: @quarterly_product_price.external_id, variants: [@original_tier.external_id], quantity: 1, perceived_price_cents: 5_99, perceived_upgrade_price_cents: 5_99 },
          billing_info: { country: "FR", state: nil, postal_code: nil }
        )

        expect(response.parsed_body).to eq(
          "success" => true,
          "reusable_token" => "cus_replacement",
          "setup_intent_id" => "seti_replacement",
          "payment_method_id" => "pm_replacement"
        )
        expect(subscription).to have_received(:reusable_pending_indian_card)
        expect(ChargeProcessor).not_to have_received(:setup_future_charges!)
      end

      it "does not reuse a pending card whose mandate was sized for the current plan" do
        end_membership
        subscription = Subscription.find(@subscription.id)
        allow(subscription).to receive(:credit_card).and_return(replacement_card)
        allow(subscription).to receive(:reusable_pending_indian_card).and_return(replacement_card)
        allow(Subscription).to receive(:find_by_external_id).with(@subscription.external_id).and_return(subscription)

        options = mint_setup_intent_for_plan(
          { price_id: @quarterly_product_price.external_id, variants: [@new_tier.external_id], quantity: 1, perceived_price_cents: 10_50, perceived_upgrade_price_cents: 10_50 },
          billing_info: { country: "FR", state: nil, postal_code: nil }
        )

        expect(response.parsed_body).to include("setup_intent_id" => "seti_replacement")
        expect(response.parsed_body).not_to have_key("payment_method_id")
        expect(options.dig(:payment_method_options, :card, :mandate_options)).to include(amount: 12_60)
      end

      it "rejects a tier from another product without creating a setup intent" do
        end_membership
        other_tier = create(:membership_product_with_preset_tiered_pricing).tiers.first

        mint_setup_intent_for_plan(
          { price_id: @quarterly_product_price.external_id, variants: [other_tier.external_id], quantity: 1, perceived_price_cents: 10_50, perceived_upgrade_price_cents: 10_50 },
          billing_info: { country: "FR", state: nil, postal_code: nil }
        )

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq("success" => false, "error_message" => "Please select a valid tier and payment option.")
        expect(ChargeProcessor).not_to have_received(:setup_future_charges!)
      end
    end
  end
end
