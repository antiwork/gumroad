# frozen_string_literal: true

require "spec_helper"

describe Integrations::DiscordController do
  before do
    sign_in create(:user)
  end

  let(:oauth_request_body) do
    {
      grant_type: "authorization_code",
      code: "test_code",
      client_id: DISCORD_CLIENT_ID,
      client_secret: DISCORD_CLIENT_SECRET,
      redirect_uri: oauth_redirect_integrations_discord_index_url
    }
  end
  let(:oauth_request_header) { { "Content-Type" => "application/x-www-form-urlencoded" } }

  describe "GET server_info" do
    it "returns server information for a valid oauth code" do
      WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { access_token: "test_access_token", guild: { id: "0", name: "Gaming" } }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:get, "#{Discordrb::API.api_base}/users/@me").
        with(headers: { "Authorization" => "Bearer test_access_token" }).
        to_return(status: 200,
                  body: { username: "gumbot" }.to_json,
                  headers: { content_type: "application/json" })

      get :server_info, format: :json, params: { code: "test_code" }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => true,
                                           "server_id" => "0",
                                           "server_name" => "Gaming",
                                           "username" => "gumbot" })
    end

    it "fails if oauth authorization fails" do
      WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 500)

      get :server_info, format: :json, params: { code: "test_code" }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if oauth authorization response does not have access token" do
      WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { guild: { id: "0", name: "Gaming" } }.to_json,
                  headers: { content_type: "application/json" })

      get :server_info, format: :json, params: { code: "test_code" }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if oauth authorization response does not have guild information" do
      WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { access_token: "test_access_token" }.to_json,
                  headers: { content_type: "application/json" })

      get :server_info, format: :json, params: { code: "test_code" }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if user identification fails" do
      WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { access_token: "test_access_token", guild: { id: "0", name: "Gaming" } }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:get, "#{Discordrb::API.api_base}/users/@me").
        with(headers: { "Authorization" => "Bearer test_access_token" }).
        to_return(status: 401, body: { code: Discordrb::Errors::Unauthorized.code }.to_json)

      get :server_info, format: :json, params: { code: "test_code" }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end
  end

  describe "GET oauth_redirect" do
    it "returns successful response if code is present" do
      get :oauth_redirect, format: :json, params: { code: "test_code" }

      expect(response.status).to eq(200)
    end

    it "fails if code is not present" do
      get :oauth_redirect, format: :json

      expect(response.status).to eq(400)
    end

    it "redirects to subdomain if specified in state" do
      user = create(:user, username: "test")

      get :oauth_redirect, format: :json, params: { code: "test_code", state: { seller_id: ObfuscateIds.encrypt(user.id), is_custom_domain: false }.to_json }

      expect(response).to redirect_to(oauth_redirect_integrations_discord_index_url(host: user.subdomain, params: { code: "test_code" }))
    end

    it "redirects to custom domain if specified in state" do
      user = create(:user, username: "test")
      custom_domain = CustomDomain.create(user:, domain: "www.test-custom-domain.com")

      get :oauth_redirect, format: :json, params: { code: "test_code", state: { seller_id: ObfuscateIds.encrypt(user.id), is_custom_domain: true }.to_json }

      expect(response).to redirect_to(oauth_redirect_integrations_discord_index_url(host: custom_domain.domain, params: { code: "test_code" }))
    end
  end

  describe "GET join_server" do
    let(:user_id) { "user-0" }
    let(:integration) { create(:discord_integration) }
    let(:product) { create(:product, active_integrations: [integration]) }
    let(:purchase) { create(:purchase, link: product) }

    it "adds member to server for a purchase with an enabled integration and a valid code" do
      WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { access_token: "test_access_token" }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:get, "#{Discordrb::API.api_base}/users/@me").
        with(headers: { "Authorization" => "Bearer test_access_token" }).
        to_return(status: 200,
                  body: { username: "gumbot", id: user_id }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:put, "#{Discordrb::API.api_base}/guilds/0/members/#{user_id}").to_return(status: 201)

      expect do
        get :join_server, format: :json, params: { code: "test_code", purchase_id: purchase.external_id }
      end.to change { PurchaseIntegration.count }.by(1)

      purchase_discord_integration = PurchaseIntegration.last
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => true, "server_name" => "Gaming" })
      expect(purchase_discord_integration.purchase).to eq(purchase)
      expect(purchase_discord_integration.integration).to eq(integration)
      expect(purchase_discord_integration.discord_user_id).to eq(user_id)
    end

    it "adds member to server for a variant purchase with an enabled integration and a valid code" do
      variant_category = create(:variant_category, link: product)
      variant = create(:variant, variant_category:, active_integrations: [integration])
      purchase = create(:purchase, link: product, variant_attributes: [variant])

      WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { access_token: "test_access_token" }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:get, "#{Discordrb::API.api_base}/users/@me").
        with(headers: { "Authorization" => "Bearer test_access_token" }).
        to_return(status: 200,
                  body: { username: "gumbot", id: user_id }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:put, "#{Discordrb::API.api_base}/guilds/0/members/#{user_id}").to_return(status: 201)

      expect do
        get :join_server, format: :json, params: { code: "test_code", purchase_id: purchase.external_id }
      end.to change { PurchaseIntegration.count }.by(1)

      purchase_discord_integration = PurchaseIntegration.last
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => true, "server_name" => "Gaming" })
      expect(purchase_discord_integration.purchase).to eq(purchase)
      expect(purchase_discord_integration.integration).to eq(integration)
      expect(purchase_discord_integration.discord_user_id).to eq(user_id)
    end

    it "fails if code is not passed" do
      expect do
        get :join_server, format: :json, params: { purchase_id: purchase.external_id }
      end.to change { PurchaseIntegration.count }.by(0)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if purchase_id is not passed" do
      expect do
        get :join_server, format: :json, params: { code: "test_code" }
      end.to change { PurchaseIntegration.count }.by(0)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if oauth authorization fails" do
      WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 500)

      expect do
        get :join_server, format: :json, params: { code: "test_code", purchase_id: purchase.external_id }
      end.to change { PurchaseIntegration.count }.by(0)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if oauth response does not have access token" do
      WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200, headers: { content_type: "application/json" })

      expect do
        get :join_server, format: :json, params: { code: "test_code", purchase_id: purchase.external_id }
      end.to change { PurchaseIntegration.count }.by(0)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if user identification fails" do
      WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { access_token: "test_access_token" }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:get, "#{Discordrb::API.api_base}/users/@me").
        with(headers: { "Authorization" => "Bearer test_access_token" }).
        to_return(status: 401, body: { code: Discordrb::Errors::Unauthorized.code }.to_json)

      expect do
        get :join_server, format: :json, params: { code: "test_code", purchase_id: purchase.external_id }
      end.to change { PurchaseIntegration.count }.by(0)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if access_token is invalid" do
      WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { access_token: "test_access_token" }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:get, "#{Discordrb::API.api_base}/users/@me").
        with(headers: { "Authorization" => "Bearer test_access_token" }).
        to_return(status: 200,
                  body: { username: "gumbot", id: user_id }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:put, "#{Discordrb::API.api_base}/guilds/0/members/#{user_id}").to_return(status: 403)

      expect do
        get :join_server, format: :json, params: { code: "test_code", purchase_id: purchase.external_id }
      end.to change { PurchaseIntegration.count }.by(0)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if purchased product does not have an integration" do
      purchase = create(:purchase)

      WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { access_token: "test_access_token" }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:get, "#{Discordrb::API.api_base}/users/@me").
        with(headers: { "Authorization" => "Bearer test_access_token" }).
        to_return(status: 200,
                  body: { username: "gumbot", id: user_id }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:put, "#{Discordrb::API.api_base}/guilds/0/members/#{user_id}").to_return(status: 403)

      expect do
        get :join_server, format: :json, params: { code: "test_code", purchase_id: purchase.external_id }
      end.to change { PurchaseIntegration.count }.by(0)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if purchase_integration record creation fails" do
      WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
        with(body: oauth_request_body, headers: oauth_request_header).
        to_return(status: 200,
                  body: { access_token: "test_access_token" }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:get, "#{Discordrb::API.api_base}/users/@me").
        with(headers: { "Authorization" => "Bearer test_access_token" }).
        to_return(status: 200,
                  body: { username: "gumbot", id: user_id }.to_json,
                  headers: { content_type: "application/json" })

      WebMock.stub_request(:put, "#{Discordrb::API.api_base}/guilds/0/members/#{user_id}").to_return(status: 403)

      allow(PurchaseIntegration).to receive(:save).and_raise(ActiveRecord::ActiveRecordError)

      expect do
        get :join_server, format: :json, params: { code: "test_code", purchase_id: purchase.external_id }
      end.to change { PurchaseIntegration.count }.by(0)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end
  end

  describe "GET leave_server" do
    let(:user_id) { "user-0" }
    let(:integration) { create(:discord_integration) }
    let(:product) { create(:product, active_integrations: [integration]) }
    let(:purchase) { create(:purchase, link: product) }

    it "removes member from server if integration is active" do
      create(:purchase_integration, integration:, purchase:, discord_user_id: user_id)

      WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/guilds/0/members/#{user_id}").to_return(status: 204)

      expect do
        get :leave_server, format: :json, params: { purchase_id: purchase.external_id }
      end.to change { purchase.live_purchase_integrations.reload.count }.by(-1)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => true, "server_name" => "Gaming" })
    end

    it "marks the purchase integration as deleted if the Discord server is deleted" do
      create(:purchase_integration, integration:, purchase:, discord_user_id: user_id)

      WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/guilds/0/members/#{user_id}").to_return(exception: Discordrb::Errors::UnknownServer)

      expect do
        get :leave_server, format: :json, params: { purchase_id: purchase.external_id }
      end.to change { purchase.live_purchase_integrations.reload.count }.by(-1)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => true, "server_name" => "Gaming" })
    end

    it "fails if purchase_id is not passed" do
      expect do
        get :leave_server, format: :json, params: {}
      end.to change { purchase.live_purchase_integrations.reload.count }.by(0)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if purchased product does not have an integration" do
      purchase = create(:purchase)

      expect do
        get :leave_server, format: :json, params: { purchase_id: purchase.external_id }
      end.to change { purchase.live_purchase_integrations.reload.count }.by(0)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if purchased product does not have an activated integration" do
      expect do
        get :leave_server, format: :json, params: { purchase_id: purchase.external_id }
      end.to change { purchase.live_purchase_integrations.reload.count }.by(0)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if call to discord api fails" do
      WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/guilds/0/members/#{user_id}").to_return(status: 500)

      expect do
        get :leave_server, format: :json, params: { purchase_id: purchase.external_id }
      end.to change { purchase.live_purchase_integrations.reload.count }.by(0)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if Discord raises a permissions error" do
      create(:purchase_integration, integration:, purchase:, discord_user_id: user_id)

      WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/guilds/0/members/#{user_id}").to_return(exception: Discordrb::Errors::NoPermission)

      expect do
        get :leave_server, format: :json, params: { purchase_id: purchase.external_id }
      end.to change { purchase.live_purchase_integrations.reload.count }.by(0)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end
  end
end
