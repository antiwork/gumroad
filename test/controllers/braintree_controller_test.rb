# frozen_string_literal: true

require "test_helper"

class BraintreeControllerTest < ActionController::TestCase
  self.described_class = BraintreeController
  self.rspec_metadata = { vcr: true }
  tests BraintreeController



  context_ BraintreeController, :vcr do
  context_ "#client_token" do
  test "returns client token in json on success" do
        get :client_token
        response_hash = response.parsed_body
        expect(response_hash["clientToken"].present?).to be true
      end

  test "returns nil in response on failure" do
        allow(Braintree::ClientToken).to receive(:generate).and_raise(Braintree::ServerError)
        get :client_token
        expect(response.body).to eq({ clientToken: nil }.to_json)
      end
    end

  context_ "#generate_transient_customer_token" do
  test "does not return anything if the nonce or the Gumroad GUID is missing" do
        cookies[:_gumroad_guid] = ""
        post :generate_transient_customer_token, params: { braintree_nonce: Braintree::Test::Nonce::PayPalFuturePayment }
        expect(response.body).to eq({ transient_customer_store_key: nil }.to_json)

        cookies[:_gumroad_guid] = "we-need-a-guid"
        post :generate_transient_customer_token
        expect(response.body).to eq({ transient_customer_store_key: nil }.to_json)
      end

  test "returns a cached key when the guid is available and the nonce is valid" do
        cookies[:_gumroad_guid] = "we-need-a-guid"
        post :generate_transient_customer_token, params: { braintree_nonce: Braintree::Test::Nonce::PayPalFuturePayment }

        expect(response.body).not_to eq({ transient_customer_store_key: nil }.to_json)
        parsed_body = response.parsed_body
        expect(parsed_body["transient_customer_store_key"]).not_to be(nil)
      end

  test "returns an error message when the nonce is invalid" do
        cookies[:_gumroad_guid] = "we-need-a-guid"
        post :generate_transient_customer_token, params: { braintree_nonce: "invalid" }

        expect(response.body).to eq({ error: "Please check your card information, we couldn't verify it." }.to_json)
      end

  test "returns an error message when the charge processor is down" do
        expect(BraintreeChargeableTransientCustomer).to receive(:tokenize_nonce_to_transient_customer).and_raise(ChargeProcessorUnavailableError)

        cookies[:_gumroad_guid] = "we-need-a-guid"
        post :generate_transient_customer_token, params: { braintree_nonce: Braintree::Test::Nonce::PayPalFuturePayment }

        expect(response.body).to eq({ error: "There is a temporary problem, please try again (your card was not charged)." }.to_json)
      end
    end
  end
end
