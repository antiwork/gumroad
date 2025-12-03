# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "helper api authorization required" do |verb, action|
  before do
    request.headers["Authorization"] = "Bearer #{GlobalConfig.get("HELPER_TOOLS_TOKEN")}"
  end

  context "when the token is invalid" do
    it "returns 401 error" do
      request.headers["Authorization"] = "Bearer invalid_token"
      public_send(verb, action)
      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to eq({ success: false, message: "authorization is invalid" }.to_json)
    end
  end

  context "when the token is missing" do
    it "returns 401 error" do
      request.headers["Authorization"] = nil
      public_send(verb, action)
      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to eq({ success: false, message: "unauthenticated" }.to_json)
    end
  end
end
