# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "admin api authorization required" do |verb, action, params = {}|
  let(:legacy_admin_actor) { respond_to?(:admin_user) ? admin_user : create(:admin_user) }

  before do
    stub_const("GUMROAD_ADMIN_ID", legacy_admin_actor.id)
    create(:admin_api_token, actor_user: legacy_admin_actor, token_hash: AdminApiToken.hash_token("test-admin-token"))
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
