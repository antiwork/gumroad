# frozen_string_literal: true

require "spec_helper"

describe Integrations::ZoomController do
  before do
    sign_in create(:user)
  end

  let(:authorization_code) { "test_code" }
  let(:oauth_request_body) do
    {
      grant_type: "authorization_code",
      code: authorization_code,
      redirect_uri: oauth_redirect_integrations_zoom_index_url
    }
  end
  let(:oauth_request_header) do
    client_id = GlobalConfig.get("ZOOM_CLIENT_ID")
    client_secret = GlobalConfig.get("ZOOM_CLIENT_SECRET")
    token = Base64.strict_encode64("#{client_id}:#{client_secret}")

    { "Authorization" => "Basic #{token}", "Content-Type" => "application/x-www-form-urlencoded" }
  end
  let(:zoom_id) { "0" }
  let(:zoom_email) { "test@zoom.com" }
  let(:access_token) { "test_access_token" }
  let(:refresh_token) { "test_refresh_token" }

  describe "GET account_info" do
    it "returns user account information for a valid oauth code" do
      WebMock.stub_request(:post, ZoomApi::ZOOM_OAUTH_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { access_token:, refresh_token: }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:get, "#{ZoomApi.base_uri}/users/me").
        with(headers: { "Authorization" => "Bearer #{access_token}" }).
        to_return(status: 200,
                  body: { id: zoom_id, email: zoom_email }.to_json,
                  headers: { content_type: "application/json" })

      get :account_info, format: :json, params: { code: authorization_code }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => true, "user_id" => zoom_id, "email" => zoom_email, "access_token" => access_token, "refresh_token" => refresh_token })
    end

    it "fails if oauth authorization fails" do
      WebMock.stub_request(:post, ZoomApi::ZOOM_OAUTH_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 500)

      get :account_info, format: :json, params: { code: authorization_code }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if oauth authorization response does not have access token" do
      WebMock.stub_request(:post, ZoomApi::ZOOM_OAUTH_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { refresh_token: }.to_json,
                  headers: { content_type: "application/json" })

      get :account_info, format: :json, params: { code: authorization_code }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if oauth authorization response does not have refresh token" do
      WebMock.stub_request(:post, ZoomApi::ZOOM_OAUTH_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { access_token: }.to_json,
                  headers: { content_type: "application/json" })

      get :account_info, format: :json, params: { code: authorization_code }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if user identification fails" do
      WebMock.stub_request(:post, ZoomApi::ZOOM_OAUTH_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { access_token:, refresh_token: }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:get, "#{ZoomApi.base_uri}/users/me").
        with(headers: { "Authorization" => "Bearer #{access_token}" }).
        to_return(status: 401)

      get :account_info, format: :json, params: { code: authorization_code }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if user id is not present" do
      WebMock.stub_request(:post, ZoomApi::ZOOM_OAUTH_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { access_token:, refresh_token: }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:get, "#{ZoomApi.base_uri}/users/me").
        with(headers: { "Authorization" => "Bearer #{access_token}" }).
        to_return(status: 200,
                  body: { email: zoom_email }.to_json,
                  headers: { content_type: "application/json" })

      get :account_info, format: :json, params: { code: authorization_code }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if user email is not present" do
      WebMock.stub_request(:post, ZoomApi::ZOOM_OAUTH_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { access_token:, refresh_token: }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:get, "#{ZoomApi.base_uri}/users/me").
        with(headers: { "Authorization" => "Bearer #{access_token}" }).
        to_return(status: 200,
                  body: { id: zoom_id }.to_json,
                  headers: { content_type: "application/json" })

      get :account_info, format: :json, params: { code: authorization_code }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end
  end

  describe "GET oauth_redirect" do
    it "returns successful response if code is present" do
      get :oauth_redirect, format: :json, params: { code: authorization_code }

      expect(response.status).to eq(200)
    end

    it "fails if code is not present" do
      get :oauth_redirect, format: :json

      expect(response.status).to eq(400)
    end
  end
end
