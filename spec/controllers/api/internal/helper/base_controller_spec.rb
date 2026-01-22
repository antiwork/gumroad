# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::Helper::BaseController do
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

  describe "authorize_hmac_signature!" do
    context "when the authentication is valid" do
      context "when the payload is in query params" do
        it "returns 200" do
          set_headers(params: @params)
          get :index, params: @params
          expect(response.status).to eq(200)
          expect(response.body).to eq({ success: true }.to_json)
        end
      end

      context "when the payload is in JSON" do
        it "returns 200" do
          set_headers(json: @params)
          post :index, params: @params
          expect(response.status).to eq(200)
          expect(response.body).to eq({ success: true }.to_json)
        end
      end
    end

    context "when authorization token is missing" do
      it "returns 401 error" do
        get :index, params: @params

        expect(response).to have_http_status(:unauthorized)
        expect(response.body).to eq({ success: false, message: "unauthenticated" }.to_json)
      end
    end

    context "when authorization token is invalid" do
      it "returns 401 error" do
        set_headers(params: @params.merge(email: "wrong.email@example.com"))
        get :index, params: @params

        expect(response).to have_http_status(:unauthorized)
        expect(response.body).to eq({ success: false, message: "authorization is invalid" }.to_json)
      end
    end

    context "when timestamp is invalid" do
      it "returns 401 error" do
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

    context "when timestamp parameter is missing" do
      it "returns 400 error" do
        params = @params.except(:timestamp)
        set_headers(params:)

        get :index, params: params

        expect(response).to have_http_status(:bad_request)
        expect(response.body).to eq({ success: false, message: "timestamp is required" }.to_json)
      end
    end
  end

  describe "authorize_helper_token!" do
    context "when the token is valid" do
      it "returns 200" do
        request.headers["Authorization"] = "Bearer #{GlobalConfig.get("HELPER_TOOLS_TOKEN")}"
        get :new
        expect(response.status).to eq(200)
        expect(response.body).to eq({ success: true }.to_json)
      end
    end

    context "when the token is invalid" do
      it "returns 401 error" do
        request.headers["Authorization"] = "Bearer invalid_token"
        get :new
        expect(response).to have_http_status(:unauthorized)
        expect(response.body).to eq({ success: false, message: "authorization is invalid" }.to_json)
      end
    end

    context "when the token is missing" do
      it "returns 401 error" do
        get :new
        expect(response).to have_http_status(:unauthorized)
        expect(response.body).to eq({ success: false, message: "unauthenticated" }.to_json)
      end
    end
  end
end
