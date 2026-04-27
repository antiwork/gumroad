# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::Admin::BaseController do
  controller(described_class) do
    def index
      render json: { success: true }
    end
  end

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("INTERNAL_ADMIN_API_TOKEN").and_return("test-admin-token")
  end

  describe "admin token authorization" do
    it "allows requests with the configured bearer token" do
      request.headers["Authorization"] = "Bearer test-admin-token"

      get :index

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq({ success: true }.to_json)
    end

    it "rejects requests with an invalid token" do
      request.headers["Authorization"] = "Bearer invalid-token"

      get :index

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to eq({ success: false, message: "authorization is invalid" }.to_json)
    end

    it "rejects requests without an authorization header" do
      get :index

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to eq({ success: false, message: "unauthenticated" }.to_json)
    end
  end
end
