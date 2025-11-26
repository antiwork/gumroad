# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_helper_api_method"

describe Api::Internal::Helper::InstantPayoutsController do
  let(:seller) { create(:user) }

  it "inherits from Api::Internal::Helper::BaseController" do
    expect(described_class.superclass).to eq(Api::Internal::Helper::BaseController)
  end

  describe "GET index" do
    include_examples "helper api authorization required", :get, :index

    context "when user is not found" do
      it "returns 404" do
        get :index, params: { email: "nonexistent@example.com" }
        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to eq("success" => false, "message" => "User not found")
      end
    end

    context "when user exists" do
      before do
        allow_any_instance_of(User).to receive(:instantly_payable_unpaid_balance_cents).and_return(5000)
      end

      it "returns instant payout balance information" do
        get :index, params: { email: seller.email }

        expect(response).to be_successful
        expect(response.parsed_body).to eq("success" => true, "balance" => "$50")
      end
    end
  end

  describe "POST create" do
    include_examples "helper api authorization required", :post, :create

    let(:params) { { email: seller.email } }
    let(:instant_payouts_service) { instance_double(InstantPayoutsService) }

    before do
      allow(InstantPayoutsService).to receive(:new).with(seller).and_return(instant_payouts_service)
    end

    context "when user is not found" do
      it "returns 404" do
        post :create, params: { email: "nonexistent@example.com" }
        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to eq("success" => false, "message" => "User not found")
      end
    end

    context "when instant payout succeeds" do
      before do
        allow(instant_payouts_service).to receive(:perform).and_return({ success: true })
      end

      it "returns success" do
        post :create, params: params
        expect(response).to be_successful
        expect(response.parsed_body).to eq("success" => true)
      end
    end

    context "when instant payout fails" do
      before do
        allow(instant_payouts_service).to receive(:perform).and_return({
                                                                         success: false,
                                                                         error: "Error message"
                                                                       })
      end

      it "returns error message" do
        post :create, params: params
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq("success" => false, "message" => "Error message")
      end
    end
  end
end
