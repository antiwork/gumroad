# frozen_string_literal: true

require "spec_helper"

describe "CORS support" do
  let(:application_domain) { DOMAIN }
  let(:origin_domain) { "example.com" }

  describe "Request to API domain" do
    let(:api_domain) { "api.gumroad.com" }

    before do
      stub_const("VALID_API_REQUEST_HOSTS", [api_domain])
    end

    it "returns a response with CORS headers" do
      post oauth_token_path, headers: { "HTTP_ORIGIN": origin_domain, "HTTP_HOST": api_domain }

      expect(response.headers["Access-Control-Allow-Origin"]).to eq "*"
      expect(response.headers["Access-Control-Allow-Methods"]).to eq "GET, POST, PUT, DELETE"
      expect(response.headers["Access-Control-Max-Age"]).to eq "7200"
    end
  end

  describe "Request to /users/session_info from VALID_CORS_ORIGINS" do
    it "returns a response with CORS headers" do
      origin = "#{PROTOCOL}://#{VALID_CORS_ORIGINS[0]}"
      get user_session_info_path, headers: { "HTTP_ORIGIN": origin, "HTTP_HOST": DOMAIN }

      expect(response.headers["Access-Control-Allow-Origin"]).to eq origin
      expect(response.headers["Access-Control-Allow-Methods"]).to eq "GET"
      expect(response.headers["Access-Control-Max-Age"]).to eq "7200"
    end
  end

  describe "Request to the public product JSON endpoint" do
    let(:origin) { "https://storefront.example.com" }

    it "returns a response with CORS headers" do
      get "/l/product.json", headers: { "HTTP_ORIGIN": origin, "HTTP_HOST": application_domain }

      expect(response.headers["Access-Control-Allow-Origin"]).to eq "*"
      expect(response.headers["Access-Control-Allow-Methods"]).to eq "GET"
      expect(response.headers["Access-Control-Max-Age"]).to eq "7200"
    end

    it "does not add CORS headers to the HTML product page path" do
      get "/l/product", headers: { "HTTP_ORIGIN": origin, "HTTP_HOST": application_domain }

      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
      expect(response.headers["Access-Control-Allow-Methods"]).to be_nil
      expect(response.headers["Access-Control-Max-Age"]).to be_nil
    end
  end

  describe "Request to the public profile JSON endpoint" do
    let(:origin) { "https://storefront.example.com" }
    let!(:seller) { create(:user, username: "seller") }

    it "returns a response with CORS headers for username JSON paths" do
      get "/seller.json", headers: { "HTTP_ORIGIN": origin, "HTTP_HOST": application_domain }

      expect(response.headers["Access-Control-Allow-Origin"]).to eq "*"
      expect(response.headers["Access-Control-Allow-Methods"]).to eq "GET"
      expect(response.headers["Access-Control-Max-Age"]).to eq "7200"
    end

    it "returns a response with CORS headers for subdomain-root JSON paths" do
      get "/.json", headers: { "HTTP_ORIGIN": origin, "HTTP_HOST": "seller.#{ROOT_DOMAIN}" }

      expect(response.headers["Access-Control-Allow-Origin"]).to eq "*"
      expect(response.headers["Access-Control-Allow-Methods"]).to eq "GET"
      expect(response.headers["Access-Control-Max-Age"]).to eq "7200"
    end

    it "does not add CORS headers to nested JSON paths" do
      get "/api/v2/user.json", headers: { "HTTP_ORIGIN": origin, "HTTP_HOST": application_domain }

      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
      expect(response.headers["Access-Control-Allow-Methods"]).to be_nil
      expect(response.headers["Access-Control-Max-Age"]).to be_nil
    end

    it "does not add CORS headers to other top-level JSON paths" do
      get "/charge_data.json", headers: { "HTTP_ORIGIN": origin, "HTTP_HOST": application_domain }

      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
      expect(response.headers["Access-Control-Allow-Methods"]).to be_nil
      expect(response.headers["Access-Control-Max-Age"]).to be_nil
    end

    it "does not raise or add CORS headers for malformed hosts" do
      expect do
        get "/seller.json", headers: { "HTTP_ORIGIN": origin, "HTTP_HOST": "evil{}host" }
      end.not_to raise_error

      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
      expect(response.headers["Access-Control-Allow-Methods"]).to be_nil
      expect(response.headers["Access-Control-Max-Age"]).to be_nil
    end

    it "does not add CORS headers to the HTML profile page path" do
      get "/seller", headers: { "HTTP_ORIGIN": origin, "HTTP_HOST": application_domain }

      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
      expect(response.headers["Access-Control-Allow-Methods"]).to be_nil
      expect(response.headers["Access-Control-Max-Age"]).to be_nil
    end
  end

  context "when the request is made to a CORS disabled domain" do
    before do
      post oauth_token_path, headers: { "HTTP_ORIGIN": origin_domain, "HTTP_HOST": application_domain }
    end

    it "returns a response without CORS headers" do
      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
      expect(response.headers["Access-Control-Allow-Methods"]).to be_nil
      expect(response.headers["Access-Control-Max-Age"]).to be_nil
    end
  end
end
