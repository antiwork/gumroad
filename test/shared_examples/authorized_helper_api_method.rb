# frozen_string_literal: true


shared_examples_for "helper api authorization required" do |verb, action|
  before do
    request.headers["Authorization"] = "Bearer #{GlobalConfig.get("HELPER_TOOLS_TOKEN")}"
  end

context_ "when the token is invalid" do
test "returns 401 error" do
      request.headers["Authorization"] = "Bearer invalid_token"
      public_send(verb, action)
      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to eq({ success: false, message: "authorization is invalid" }.to_json)
    end
  end

context_ "when the token is missing" do
test "returns 401 error" do
      request.headers["Authorization"] = nil
      public_send(verb, action)
      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to eq({ success: false, message: "unauthenticated" }.to_json)
    end
  end
end
