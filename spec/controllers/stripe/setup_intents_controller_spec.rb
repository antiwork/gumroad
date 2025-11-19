# frozen_string_literal: true

require "spec_helper"

describe Stripe::SetupIntentsController, :vcr do
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
