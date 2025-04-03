# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

RSpec.describe StripeAccountSessionsController do
  let(:seller) { create(:named_seller) }
  let(:connected_account_id) { "acct_123" }

  before do
    sign_in(seller)
  end

  describe "#create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:policy_klass) { StripeAccountSessions::UserPolicy }
      let(:record) { seller }
    end

    context "when seller has a stripe account" do
      before do
        allow_any_instance_of(User).to receive(:stripe_account).and_return(double(charge_processor_merchant_id: connected_account_id))
      end

      it "creates a stripe account session" do
        stripe_session = double(client_secret: "secret_123")
        expect(Stripe::AccountSession).to receive(:create).with(
          {
            account: connected_account_id,
            components: {
              notification_banner: {
                enabled: true,
                features: { external_account_collection: true }
              }
            }
          }
        ).and_return(stripe_session)

        post :create
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq(
          "success" => true,
          "client_secret" => "secret_123"
        )
      end

      it "handles stripe errors" do
        expect(Stripe::AccountSession).to receive(:create).and_raise(StandardError.new("Stripe error"))
        expect(Bugsnag).to receive(:notify).with("Failed to create stripe account session for user #{seller.id}: Stripe error")

        post :create
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq(
          "success" => false,
          "error_message" => "Failed to create stripe account session"
        )
      end
    end

    context "when seller does not have a stripe account" do
      before do
        allow_any_instance_of(User).to receive(:stripe_account).and_return(nil)
      end

      it "returns an error" do
        post :create
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq(
          "success" => false,
          "error_message" => "User does not have a Stripe account"
        )
      end
    end
  end
end
