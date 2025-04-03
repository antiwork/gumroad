# frozen_string_literal: true

require "spec_helper"

describe Integrations::GoogleCalendarController do
  before do
    sign_in create(:user)
  end

  let(:authorization_code) { "test_code" }
  let(:oauth_request_body) do
    {
      grant_type: "authorization_code",
      code: authorization_code,
      redirect_uri: oauth_redirect_integrations_google_calendar_index_url,
      client_id: GlobalConfig.get("GOOGLE_CLIENT_ID"),
      client_secret: GlobalConfig.get("GOOGLE_CLIENT_SECRET"),
    }
  end
  let(:calendar_id) { "0" }
  let(:calendar_summary) { "Holidays" }
  let(:access_token) { "test_access_token" }
  let(:refresh_token) { "test_refresh_token" }
  let(:email) { "hi@gmail.com" }

  describe "GET account_info" do
    it "returns user account information for a valid oauth code" do
      WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/token").with(body: oauth_request_body).
        to_return(status: 200, body: { access_token:, refresh_token: }.to_json, headers: { content_type: "application/json" })

      WebMock.stub_request(:get, "#{GoogleCalendarApi.base_uri}/oauth2/v2/userinfo").with(query: { access_token: }).
        to_return(status: 200, body: { email: }.to_json, headers: { content_type: "application/json" })

      get :account_info, format: :json, params: { code: authorization_code }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => true, "access_token" => access_token, "refresh_token" => refresh_token, "email" => email })
    end

    it "fails if oauth authorization fails" do
      WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/token").with(body: oauth_request_body).
        to_return(status: 500)

      get :account_info, format: :json, params: { code: authorization_code }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if oauth authorization response does not have access token" do
      WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/token").with(body: oauth_request_body).
        to_return(status: 200, body: { refresh_token: }.to_json, headers: { content_type: "application/json" })

      get :account_info, format: :json, params: { code: authorization_code }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if oauth authorization response does not have refresh token" do
      WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/token").with(body: oauth_request_body).
        to_return(status: 200, body: { access_token: }.to_json, headers: { content_type: "application/json" })

      get :account_info, format: :json, params: { code: authorization_code }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if user info request fails" do
      WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/token").with(body: oauth_request_body).
        to_return(status: 200, body: { access_token:, refresh_token: }.to_json, headers: { content_type: "application/json" })

      WebMock.stub_request(:get, "#{GoogleCalendarApi.base_uri}/oauth2/v2/userinfo").with(query: { access_token: }).to_return(status: 404)

      get :account_info, format: :json, params: { code: authorization_code }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if user info response does not have email" do
      WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/token").with(body: oauth_request_body).
        to_return(status: 200, body: { access_token:, refresh_token: }.to_json, headers: { content_type: "application/json" })

      WebMock.stub_request(:get, "#{GoogleCalendarApi.base_uri}/oauth2/v2/userinfo").with(query: { access_token: }).
        to_return(status: 200, body: {}.to_json, headers: { content_type: "application/json" })

      get :account_info, format: :json, params: { code: authorization_code }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end
  end

  describe "GET calendar_list" do
    it "returns list of calendars from the google account associated with the access_token" do
      WebMock.stub_request(:get, "#{GoogleCalendarApi.base_uri}/calendar/v3/users/me/calendarList").with(headers: { "Authorization" => "Bearer #{access_token}" }).
        to_return(status: 200, body: {
          items: [
            { id: "0", summary: "Holidays", meta: "somemeta" },
            { id: "1", summary: "Work", meta: "somemeta2" },
            { id: "2", summary: "Personal", meta: "somemeta3" }]
        }.to_json, headers: { content_type: "application/json" })

      get :calendar_list, format: :json, params: { access_token:, refresh_token: }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => true, "calendar_list" => [{ "id" => "0", "summary" => "Holidays" }, { "id" => "1", "summary" => "Work" }, { "id" => "2", "summary" => "Personal" }] })
    end

    it "fails if the Google API for calendar list returns an error" do
      WebMock.stub_request(:get, "#{GoogleCalendarApi.base_uri}/calendar/v3/users/me/calendarList").with(headers: { "Authorization" => "Bearer #{access_token}" }).
        to_return(status: 404, headers: { content_type: "application/json" })

      get :calendar_list, format: :json, params: { access_token:, refresh_token: }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    describe "uses refresh_token if access_token is expired" do
      it "returns list of calendars from the google account associated with the access_token" do
        WebMock.stub_request(:get, "#{GoogleCalendarApi.base_uri}/calendar/v3/users/me/calendarList").with(headers: { "Authorization" => "Bearer #{access_token}" }).
          to_return(status: 401, headers: { content_type: "application/json" })

        WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/token").
          with(
            body: {
              grant_type: "refresh_token",
              refresh_token:,
              client_id: GlobalConfig.get("GOOGLE_CLIENT_ID"),
              client_secret: GlobalConfig.get("GOOGLE_CLIENT_SECRET"),
            }).
          to_return(status: 200, body: {
            access_token: "fresh_access_token",
            expires_in: 3600
          }.to_json, headers: { content_type: "application/json" })

        WebMock.stub_request(:get, "#{GoogleCalendarApi.base_uri}/calendar/v3/users/me/calendarList").with(headers: { "Authorization" => "Bearer fresh_access_token" }).
          to_return(status: 200, body: {
            items: [
              { id: "0", summary: "Holidays", meta: "somemeta" },
              { id: "1", summary: "Work", meta: "somemeta2" },
              { id: "2", summary: "Personal", meta: "somemeta3" }]
          }.to_json, headers: { content_type: "application/json" })

        get :calendar_list, format: :json, params: { access_token:, refresh_token: }

        expect(response.status).to eq(200)
        expect(response.parsed_body).to eq({ "success" => true, "calendar_list" => [{ "id" => "0", "summary" => "Holidays" }, { "id" => "1", "summary" => "Work" }, { "id" => "2", "summary" => "Personal" }] })
      end

      it "fails if request for refresh token fails" do
        WebMock.stub_request(:get, "#{GoogleCalendarApi.base_uri}/calendar/v3/users/me/calendarList").with(headers: { "Authorization" => "Bearer #{access_token}" }).
          to_return(status: 401, headers: { content_type: "application/json" })

        WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/token").
          with(
            body: {
              grant_type: "refresh_token",
              refresh_token:,
              client_id: GlobalConfig.get("GOOGLE_CLIENT_ID"),
              client_secret: GlobalConfig.get("GOOGLE_CLIENT_SECRET"),
            }).
          to_return(status: 400, headers: { content_type: "application/json" })

        get :calendar_list, format: :json, params: { access_token:, refresh_token: }

        expect(response.status).to eq(200)
        expect(response.parsed_body).to eq({ "success" => false })
      end

      it "fails if refresh token response does not have access token" do
        WebMock.stub_request(:get, "#{GoogleCalendarApi.base_uri}/calendar/v3/users/me/calendarList").with(headers: { "Authorization" => "Bearer #{access_token}" }).
          to_return(status: 401, headers: { content_type: "application/json" })

        WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/token").
          with(
            body: {
              grant_type: "refresh_token",
              refresh_token:,
              client_id: GlobalConfig.get("GOOGLE_CLIENT_ID"),
              client_secret: GlobalConfig.get("GOOGLE_CLIENT_SECRET"),
            }).
          to_return(status: 200, body: { expires_in: 3600 }.to_json, headers: { content_type: "application/json" })

        get :calendar_list, format: :json, params: { access_token:, refresh_token: }

        expect(response.status).to eq(200)
        expect(response.parsed_body).to eq({ "success" => false })
      end
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
