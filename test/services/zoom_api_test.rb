# frozen_string_literal: true

require "test_helper"

class ZoomApiTest < ActiveSupport::TestCase
  self.described_class = ZoomApi



  context_ ZoomApi do
    let(:oauth_request_header) do
      client_id = GlobalConfig.get("ZOOM_CLIENT_ID")
      client_secret = GlobalConfig.get("ZOOM_CLIENT_SECRET")
      token = Base64.strict_encode64("#{client_id}:#{client_secret}")

      { "Authorization" => "Basic #{token}", "Content-Type" => "application/x-www-form-urlencoded" }
    end

  context_ "POST oauth_token" do
  test "makes an oauth authorization request with the given code and redirect uri" do
        WebMock.stub_request(:post, ZoomApi::ZOOM_OAUTH_URL).
          with(
            body: {
              grant_type: "authorization_code",
              code: "test_code",
              redirect_uri: "test_uri"
            },
            headers: oauth_request_header)

        response = ZoomApi.new.oauth_token("test_code", "test_uri")
        expect(response.success?).to eq(true)
      end
    end

  context_ "GET user_info" do
  test "requests user information with the given user token" do
        WebMock.stub_request(:get, "#{ZoomApi.base_uri}/users/me").with(headers: { "Authorization" => "Bearer test_token" })

        response = ZoomApi.new.user_info("test_token")
        expect(response.success?).to eq(true)
      end
    end
  end
end
