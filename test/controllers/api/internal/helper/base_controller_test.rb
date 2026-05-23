# frozen_string_literal: true

require "test_helper"

class ApiInternalHelperBaseControllerTest < ActionController::TestCase
  self.described_class = Api::Internal::Helper::BaseController
  tests Api::Internal::Helper::BaseController



  context_ Api::Internal::Helper::BaseController do
    include HelperAISpecHelper

    controller(described_class) do
      before_action :authorize_hmac_signature!, only: :index
      skip_before_action :authorize_helper_token!, only: :index

      def index
        render json: { success: true }
      end

      def new
        render json: { success: true }
      end
    end

    before do
      @params = { email: "test@example.com", timestamp: Time.now.to_i }
    end

  context_ "authorize_hmac_signature!" do
  context_ "when the authentication is valid" do
  context_ "when the payload is in query params" do
  test "returns 200" do
            set_headers(params: @params)
            get :index, params: @params
            expect(response.status).to eq(200)
            expect(response.body).to eq({ success: true }.to_json)
          end
        end

  context_ "when the payload is in JSON" do
  test "returns 200" do
            set_headers(json: @params)
            post :index, params: @params
            expect(response.status).to eq(200)
            expect(response.body).to eq({ success: true }.to_json)
          end
        end
      end

  context_ "when authorization token is missing" do
  test "returns 401 error" do
          get :index, params: @params

          expect(response).to have_http_status(:unauthorized)
          expect(response.body).to eq({ success: false, message: "unauthenticated" }.to_json)
        end
      end

  context_ "when authorization token is invalid" do
  test "returns 401 error" do
          set_headers(params: @params.merge(email: "wrong.email@example.com"))
          get :index, params: @params

          expect(response).to have_http_status(:unauthorized)
          expect(response.body).to eq({ success: false, message: "authorization is invalid" }.to_json)
        end
      end

  context_ "when timestamp is invalid" do
  test "returns 401 error" do
          params = @params.merge(timestamp: (Api::Internal::Helper::BaseController::HMAC_EXPIRATION + 5.second).ago.to_i)
          set_headers(params:)

          get :index, params: params

          expect(response).to have_http_status(:unauthorized)
          expect(response.body).to eq({ success: false, message: "bad timestamp" }.to_json)

          params = @params.merge(timestamp: (Time.now + Api::Internal::Helper::BaseController::HMAC_EXPIRATION + 5.second).to_i)
          set_headers(params:)

          get :index, params: params

          expect(response).to have_http_status(:unauthorized)
          expect(response.body).to eq({ success: false, message: "bad timestamp" }.to_json)
        end
      end

  context_ "when timestamp parameter is missing" do
  test "returns 400 error" do
          params = @params.except(:timestamp)
          set_headers(params:)

          get :index, params: params

          expect(response).to have_http_status(:bad_request)
          expect(response.body).to eq({ success: false, message: "timestamp is required" }.to_json)
        end
      end
    end

  context_ "authorize_helper_token!" do
  context_ "when the token is valid" do
  test "returns 200" do
          request.headers["Authorization"] = "Bearer #{GlobalConfig.get("HELPER_TOOLS_TOKEN")}"
          get :new
          expect(response.status).to eq(200)
          expect(response.body).to eq({ success: true }.to_json)
        end
      end

  context_ "when the token is invalid" do
  test "returns 401 error" do
          request.headers["Authorization"] = "Bearer invalid_token"
          get :new
          expect(response).to have_http_status(:unauthorized)
          expect(response.body).to eq({ success: false, message: "authorization is invalid" }.to_json)
        end
      end

  context_ "when the token is missing" do
  test "returns 401 error" do
          get :new
          expect(response).to have_http_status(:unauthorized)
          expect(response.body).to eq({ success: false, message: "unauthenticated" }.to_json)
        end
      end
    end
  end
end
