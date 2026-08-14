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

      it "uses the logged in user when deriving a subscription update mandate amount" do
        logged_in_user = create(:user)
        subscription = create(:subscription)
        chargeable = double(requires_mandate?: true)
        allow(controller).to receive(:logged_in_user).and_return(logged_in_user)
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(products: [{ price: 0, subscription_id: subscription.external_id, recurrence: "quarterly" }]))
        expect(subscription).to receive(:current_subscription_price_cents).with(authenticated_offer_code_buyer: logged_in_user).and_return(12_34)

        mandate_options = controller.send(:mandate_options_for_stripe, chargeable, subscription:)
        mandate_terms = mandate_options.dig(:payment_method_options, :card, :mandate_options)

        expect(mandate_options[:metadata]).to eq(gumroad_subscription_id: subscription.external_id)
        expect(mandate_terms).to include(
          amount: 12_34,
          currency: Currency::USD,
          interval: "month",
          interval_count: 3,
          reference: StripeChargeProcessor::MANDATE_PREFIX + subscription.external_id
        )
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
