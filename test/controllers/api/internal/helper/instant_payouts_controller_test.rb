# frozen_string_literal: true

require "test_helper"
require "shared_examples/authorized_helper_api_method"

class ApiInternalHelperInstantPayoutsControllerTest < ActionController::TestCase
  self.described_class = Api::Internal::Helper::InstantPayoutsController
  tests Api::Internal::Helper::InstantPayoutsController



  context_ Api::Internal::Helper::InstantPayoutsController do
    let(:seller) { create(:user) }

  test "inherits from Api::Internal::Helper::BaseController" do
      expect(described_class.superclass).to eq(Api::Internal::Helper::BaseController)
    end

  context_ "GET index" do
      include_examples "helper api authorization required", :get, :index

  context_ "when user is not found" do
  test "returns 404" do
          get :index, params: { email: "nonexistent@example.com" }
          expect(response).to have_http_status(:not_found)
          expect(response.parsed_body).to eq("success" => false, "message" => "User not found")
        end
      end

  context_ "when user exists" do
        before do
          allow_any_instance_of(User).to receive(:instantly_payable_unpaid_balance_cents).and_return(5000)
        end

  test "returns instant payout balance information" do
          get :index, params: { email: seller.email }

          expect(response).to be_successful
          expect(response.parsed_body).to eq("success" => true, "balance" => "$50")
        end
      end
    end

  context_ "POST create" do
      include_examples "helper api authorization required", :post, :create

      let(:params) { { email: seller.email } }
      let(:instant_payouts_service) { instance_double(InstantPayoutsService) }

      before do
        allow(InstantPayoutsService).to receive(:new).with(seller).and_return(instant_payouts_service)
      end

  context_ "when user is not found" do
  test "returns 404" do
          post :create, params: { email: "nonexistent@example.com" }
          expect(response).to have_http_status(:not_found)
          expect(response.parsed_body).to eq("success" => false, "message" => "User not found")
        end
      end

  context_ "when instant payout succeeds" do
        before do
          allow(instant_payouts_service).to receive(:perform).and_return({ success: true })
        end

  test "returns success" do
          post :create, params: params
          expect(response).to be_successful
          expect(response.parsed_body).to eq("success" => true)
        end
      end

  context_ "when instant payout fails" do
        before do
          allow(instant_payouts_service).to receive(:perform).and_return({
                                                                           success: false,
                                                                           error: "Error message"
                                                                         })
        end

  test "returns error message" do
          post :create, params: params
          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.parsed_body).to eq("success" => false, "message" => "Error message")
        end
      end
    end
  end
end
