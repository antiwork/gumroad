# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "admin api authorization required" do |verb, action, params = {}|
  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("INTERNAL_ADMIN_API_TOKEN").and_return("test-admin-token")
    request.headers["Authorization"] = "Bearer test-admin-token"
  end

  context "when the token is invalid" do
    it "returns 401 error" do
      request.headers["Authorization"] = "Bearer invalid-token"
      public_send(verb, action, params:)
      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to eq({ success: false, message: "authorization is invalid" }.to_json)
    end
  end

  context "when the token is missing" do
    it "returns 401 error" do
      request.headers["Authorization"] = nil
      public_send(verb, action, params:)
      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to eq({ success: false, message: "unauthenticated" }.to_json)
    end
  end
end
