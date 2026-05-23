# frozen_string_literal: true

require "test_helper"

class RequestsCorsHeadersTest < ActionDispatch::IntegrationTest



  context_ "CORS support" do
    let(:application_domain) { "gumroad.com" }
    let(:origin_domain) { "example.com" }

  context_ "Request to API domain" do
      let(:api_domain) { "api.gumroad.com" }

      before do
        stub_const("VALID_API_REQUEST_HOSTS", [api_domain])
      end

  test "returns a response with CORS headers" do
        post oauth_token_path, headers: { "HTTP_ORIGIN": origin_domain, "HTTP_HOST": api_domain }

        expect(response.headers["Access-Control-Allow-Origin"]).to eq "*"
        expect(response.headers["Access-Control-Allow-Methods"]).to eq "GET, POST, PUT, DELETE"
        expect(response.headers["Access-Control-Max-Age"]).to eq "7200"
      end
    end

  context_ "Request to /users/session_info from VALID_CORS_ORIGINS" do
  test "returns a response with CORS headers" do
        origin = "#{PROTOCOL}://#{VALID_CORS_ORIGINS[0]}"
        get user_session_info_path, headers: { "HTTP_ORIGIN": origin, "HTTP_HOST": DOMAIN }

        expect(response.headers["Access-Control-Allow-Origin"]).to eq origin
        expect(response.headers["Access-Control-Allow-Methods"]).to eq "GET"
        expect(response.headers["Access-Control-Max-Age"]).to eq "7200"
      end
    end

  context_ "when the request is made to a CORS disabled domain" do
      before do
        post oauth_token_path, headers: { "HTTP_ORIGIN": origin_domain, "HTTP_HOST": application_domain }
      end

  test "returns a response without CORS headers" do
        expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
        expect(response.headers["Access-Control-Allow-Methods"]).to be_nil
        expect(response.headers["Access-Control-Max-Age"]).to be_nil
      end
    end
  end
end
