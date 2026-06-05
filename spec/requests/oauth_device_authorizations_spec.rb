# frozen_string_literal: true

require "spec_helper"

describe "OAuth device authorizations", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:named_user, name: "Gianfranco", email: "gianfranco@example.com") }
  let(:oauth_application) { create(:oauth_application, owner: user, name: "Gumroad CLI", scopes: "view_profile edit_products", confidential: false, device_authorization_enabled: true) }

  before do
    host! DOMAIN
    stub_vite_layout_helpers
  end

  describe "POST /oauth/device/code" do
    it "creates a pending device authorization and returns the device flow payload" do
      expect do
        post oauth_device_code_path, params: { client_id: oauth_application.uid, scope: "view_profile" }, headers: { "REMOTE_ADDR" => "203.0.113.10", "HTTP_USER_AGENT" => "Gumroad CLI" }
      end.to change { OauthDeviceAuthorization.count }.by(1)

      body = response.parsed_body
      device_authorization = OauthDeviceAuthorization.last

      expect(response).to have_http_status(:ok)
      expect(body).to include(
        "device_code" => be_present,
        "user_code" => a_string_matching(/\AGRD-[A-Z0-9]{4}-[A-Z0-9]{4}\z/),
        "verification_uri" => oauth_device_authorization_url,
        "verification_uri_complete" => oauth_device_authorization_url(user_code: body["user_code"]),
        "expires_in" => OauthDeviceAuthorization::EXPIRES_IN.to_i,
        "interval" => OauthDeviceAuthorization::POLL_INTERVAL.to_i
      )
      expect(device_authorization).to have_attributes(
        oauth_application:,
        scopes: "view_profile",
        status: OauthDeviceAuthorization::STATUS_PENDING,
        created_ip_address: "203.0.113.10",
        created_user_agent: "Gumroad CLI"
      )
      expect(device_authorization.device_code_digest).to eq(OauthDeviceAuthorization.digest(body["device_code"]))
      expect(device_authorization.user_code_digest).to eq(OauthDeviceAuthorization.digest(OauthDeviceAuthorization.normalize_user_code(body["user_code"])))
      expect(device_authorization.device_code_digest).not_to eq(body["device_code"])
      expect(device_authorization.user_code_digest).not_to eq(body["user_code"])
    end

    it "rejects scopes the application cannot request" do
      expect do
        post oauth_device_code_path, params: { client_id: oauth_application.uid, scope: "mobile_api" }
      end.not_to change { OauthDeviceAuthorization.count }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("error" => "invalid_scope")
    end

    it "uses the application's scopes when scope is omitted" do
      expect do
        post oauth_device_code_path, params: { client_id: oauth_application.uid }
      end.to change { OauthDeviceAuthorization.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(OauthDeviceAuthorization.last).to have_attributes(scopes: "view_profile edit_products")
    end

    it "rejects non-scalar scopes" do
      expect do
        post oauth_device_code_path, params: { client_id: oauth_application.uid, scope: { bad: "1" } }
      end.not_to change { OauthDeviceAuthorization.count }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("error" => "invalid_scope")
    end

    it "rejects clients that are not opted in to device authorization" do
      unauthorized_application = create(:oauth_application, owner: user, scopes: "view_profile", confidential: false, device_authorization_enabled: false)

      expect do
        post oauth_device_code_path, params: { client_id: unauthorized_application.uid, scope: "view_profile" }
      end.not_to change { OauthDeviceAuthorization.count }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("error" => "unauthorized_client")
    end

    it "returns canonical Gumroad verification URLs when called from the API host" do
      host! API_DOMAIN

      post oauth_device_code_path, params: { client_id: oauth_application.uid, scope: "view_profile" }

      body = response.parsed_body
      expect(response).to have_http_status(:ok)
      expect(body).to include(
        "verification_uri" => oauth_device_authorization_url(host: DOMAIN, protocol: PROTOCOL),
        "verification_uri_complete" => oauth_device_authorization_url(host: DOMAIN, protocol: PROTOCOL, user_code: body["user_code"])
      )
    end

    it "requires the client secret for confidential applications" do
      confidential_application = create(:oauth_application, owner: user, scopes: "view_profile", confidential: true, secret: "client-secret", device_authorization_enabled: true)

      post oauth_device_code_path, params: { client_id: confidential_application.uid, scope: "view_profile" }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to include("error" => "invalid_client")

      post oauth_device_code_path, params: { client_id: confidential_application.uid, client_secret: "client-secret", scope: "view_profile" }

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /oauth/device" do
    it "redirects to login with the code preserved before showing approval details" do
      body = create_device_code

      get oauth_device_authorization_path, params: { user_code: body["user_code"] }

      expect(response).to redirect_to(login_path(next: oauth_device_authorization_path(user_code: body["user_code"])))
    end

    it "shows the application and scopes after login" do
      body = create_device_code
      sign_in user

      get oauth_device_authorization_path, params: { user_code: body["user_code"] }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Authorize")
      expect(response.body).to include("Gumroad CLI")
      expect(response.body).to include("See your profile data.")
    end

    it "shows expired codes without redirecting to login" do
      device_authorization = create(:oauth_device_authorization, oauth_application:, user_code: "GRD-EXPR-0001", expires_at: 1.second.ago)

      get oauth_device_authorization_path, params: { user_code: "GRD-EXPR-0001" }

      expect(response).to have_http_status(:ok)
      expect(response).not_to be_redirect
      expect(response.body).to include("This code has expired.")
      expect(device_authorization.reload).to have_attributes(status: OauthDeviceAuthorization::STATUS_PENDING, resource_owner: nil)
    end

    it "blocks approval while the signed-in admin is impersonating another user" do
      body = create_device_code
      admin = create(:admin_user)
      sign_in admin
      $redis.set(RedisKey.impersonated_user(admin.id), user.id)

      get oauth_device_authorization_path, params: { user_code: body["user_code"] }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Stop impersonating before authorizing an OAuth application.")
      expect(response.body).not_to include("This application will be able to:")

      expect do
        submit_device_authorization(body["user_code"], decision: "approve")
      end.not_to change { Doorkeeper::AccessToken.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(OauthDeviceAuthorization.last).to have_attributes(status: OauthDeviceAuthorization::STATUS_PENDING, resource_owner: nil)
    ensure
      $redis.del(RedisKey.impersonated_user(admin.id)) if defined?(admin) && admin&.persisted?
    end
  end

  describe "POST /oauth/device and POST /oauth/token" do
    it "lets the user approve a code and lets the polling client exchange it for a normal token" do
      body = create_device_code
      sign_in user

      submit_device_authorization(body["user_code"], decision: "approve")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Authorization complete")
      expect(OauthDeviceAuthorization.last).to have_attributes(
        status: OauthDeviceAuthorization::STATUS_APPROVED,
        resource_owner: user,
        approved_at: be_present
      )

      expect do
        post oauth_token_path, params: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, client_id: oauth_application.uid, device_code: body["device_code"] }
      end.to change { Doorkeeper::AccessToken.count }.by(1)

      token_body = response.parsed_body
      access_token = Doorkeeper::AccessToken.last

      expect(response).to have_http_status(:ok)
      expect(token_body).to include(
        "access_token" => access_token.token,
        "token_type" => "Bearer",
        "refresh_token" => access_token.refresh_token,
        "scope" => "view_profile"
      )
      expect(access_token).to have_attributes(application_id: oauth_application.id, resource_owner_id: user.id)
      expect(access_token.scopes.to_s).to eq("view_profile")
      expect(Doorkeeper::AccessGrant.where(
        application_id: oauth_application.id,
        resource_owner_id: user.id,
        scopes: "view_profile",
        redirect_uri: OauthDeviceAuthorization::DEVICE_REDIRECT_URI
      )).to exist
      expect(OauthDeviceAuthorization.last).to have_attributes(status: OauthDeviceAuthorization::STATUS_CONSUMED, access_token:)
      expect(OauthApplication.authorized_for(user)).to include(oauth_application)

      consumed_authorization = OauthDeviceAuthorization.last
      consumed_poll_count = consumed_authorization.poll_count
      post oauth_token_path, params: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, client_id: oauth_application.uid, device_code: body["device_code"] }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("error" => "expired_token")
      expect(consumed_authorization.reload).to have_attributes(poll_count: consumed_poll_count)

      oauth_application.revoke_access_for(user)

      expect(access_token.reload).to be_revoked
    end

    it "does not exchange an approved code after the user revokes the application" do
      access_token = create(
        "doorkeeper/access_token",
        application: oauth_application,
        resource_owner_id: user.id,
        scopes: "view_profile"
      )
      body = create_device_code
      sign_in user

      submit_device_authorization(body["user_code"], decision: "approve")
      device_authorization = OauthDeviceAuthorization.last
      oauth_application.revoke_access_for(user)

      expect(access_token.reload).to be_revoked
      expect(device_authorization.reload).to have_attributes(
        status: OauthDeviceAuthorization::STATUS_DENIED,
        denied_at: be_present,
        access_token: nil
      )
      expect do
        post oauth_token_path,
             params: {
               grant_type: OauthDeviceAuthorization::GRANT_TYPE,
               client_id: oauth_application.uid,
               device_code: body["device_code"]
             }
      end.not_to change { Doorkeeper::AccessToken.count }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("error" => "access_denied")
    end

    it "does not approve a pending code after the user revokes the application" do
      access_token = create(
        "doorkeeper/access_token",
        application: oauth_application,
        resource_owner_id: user.id,
        scopes: "view_profile"
      )
      body = create_device_code
      device_authorization = OauthDeviceAuthorization.last
      oauth_application.revoke_access_for(user)
      sign_in user

      get oauth_device_authorization_path, params: { user_code: body["user_code"] }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("This code is invalid or expired.")
      expect(response.body).not_to include("This application will be able to:")

      expect do
        submit_device_authorization(body["user_code"], decision: "approve")
      end.not_to change { Doorkeeper::AccessToken.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("This code is invalid or expired.")
      expect(response.body).not_to include("Authorization complete")
      expect(access_token.reload).to be_revoked
      expect(device_authorization.reload).to have_attributes(
        status: OauthDeviceAuthorization::STATUS_DENIED,
        denied_at: be_present,
        resource_owner: user,
        access_token: nil
      )

      post oauth_token_path, params: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, client_id: oauth_application.uid, device_code: body["device_code"] }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("error" => "access_denied")
    end

    it "does not return a successful token response when the issued token is revoked before rendering" do
      body = create_device_code
      sign_in user
      submit_device_authorization(body["user_code"], decision: "approve")
      allow_any_instance_of(OauthDeviceAuthorization).to receive(:poll!).and_wrap_original do |method, *args, **kwargs|
        kwargs = args.pop if kwargs.empty? && args.last.is_a?(Hash)
        status, access_token = method.call(*args, **kwargs)
        access_token.update!(revoked_at: Time.current) if status == OauthDeviceAuthorization::POLL_APPROVED
        [status, access_token]
      end

      expect do
        post oauth_token_path,
             params: {
               grant_type: OauthDeviceAuthorization::GRANT_TYPE,
               client_id: oauth_application.uid,
               device_code: body["device_code"]
             }
      end.to change { Doorkeeper::AccessToken.count }.by(1)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("error" => "access_denied")
      expect(Doorkeeper::AccessToken.last).to be_revoked
    end

    it "shows completion when the approving user reloads before the client polls" do
      body = create_device_code
      sign_in user

      submit_device_authorization(body["user_code"], decision: "approve")
      get oauth_device_authorization_path, params: { user_code: body["user_code"] }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Authorization complete")
      expect(response.body).not_to include("This code is invalid or expired.")
    end

    it "does not show completion for an approved code to a different user" do
      body = create_device_code
      other_user = create(:named_user, name: "Other User", email: "other@example.com")
      sign_in user

      submit_device_authorization(body["user_code"], decision: "approve")
      sign_out user
      sign_in other_user
      get oauth_device_authorization_path, params: { user_code: body["user_code"] }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("This code is invalid or expired.")
      expect(response.body).not_to include("Authorization complete")
    end

    it "does not show completion when approving an already approved code again" do
      body = create_device_code
      sign_in user

      submit_device_authorization(body["user_code"], decision: "approve")
      submit_device_authorization(body["user_code"], decision: "approve")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("This code is invalid or expired.")
      expect(response.body).not_to include("Authorization complete")
    end

    it "does not exchange an approved code after device authorization is disabled for the client" do
      body = create_device_code
      sign_in user
      submit_device_authorization(body["user_code"], decision: "approve")
      oauth_application.update!(device_authorization_enabled: false)

      expect do
        post oauth_token_path, params: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, client_id: oauth_application.uid, device_code: body["device_code"] }
      end.not_to change { Doorkeeper::AccessToken.count }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("error" => "unauthorized_client")
      expect(OauthDeviceAuthorization.last).to have_attributes(status: OauthDeviceAuthorization::STATUS_APPROVED, access_token: nil)
    end

    it "does not approve malformed authorization decisions" do
      body = create_device_code
      sign_in user

      expect do
        submit_device_authorization(body["user_code"], decision: "maybe")
      end.not_to change { Doorkeeper::AccessToken.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Choose whether to authorize or deny this application.")
      expect(OauthDeviceAuthorization.last).to have_attributes(status: OauthDeviceAuthorization::STATUS_PENDING, resource_owner: nil)
    end

    it "does not show approval success when the approval transition loses a race" do
      body = create_device_code
      sign_in user
      allow_any_instance_of(OauthDeviceAuthorization).to receive(:approve!).and_return(false)

      submit_device_authorization(body["user_code"], decision: "approve")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("This code is invalid or expired.")
      expect(response.body).not_to include("Authorization complete")
      expect(OauthDeviceAuthorization.last).to have_attributes(status: OauthDeviceAuthorization::STATUS_PENDING, resource_owner: nil)
    end

    it "does not show denial success when the denial transition loses a race" do
      body = create_device_code
      sign_in user
      allow_any_instance_of(OauthDeviceAuthorization).to receive(:deny!).and_return(false)

      submit_device_authorization(body["user_code"], decision: "deny")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("This code is invalid or expired.")
      expect(response.body).not_to include("Authorization denied")
      expect(OauthDeviceAuthorization.last).to have_attributes(status: OauthDeviceAuthorization::STATUS_PENDING, resource_owner: nil)
    end

    it "does not approve a code after device authorization is disabled for the client" do
      body = create_device_code
      oauth_application.update!(device_authorization_enabled: false)
      sign_in user

      get oauth_device_authorization_path, params: { user_code: body["user_code"] }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("This code is invalid.")
      expect(response.body).not_to include("This application will be able to:")

      submit_device_authorization(body["user_code"], decision: "approve")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("This code is invalid.")
      expect(response.body).not_to include("Authorization complete")
      expect(OauthDeviceAuthorization.last).to have_attributes(status: OauthDeviceAuthorization::STATUS_PENDING, resource_owner: nil)
    end

    it "does not approve a code after the client is deleted" do
      body = create_device_code
      oauth_application.mark_deleted!
      sign_in user

      get oauth_device_authorization_path, params: { user_code: body["user_code"] }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("This code is invalid.")
      expect(response.body).not_to include("This application will be able to:")

      submit_device_authorization(body["user_code"], decision: "approve")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("This code is invalid.")
      expect(response.body).not_to include("Authorization complete")
      expect(OauthDeviceAuthorization.last).to have_attributes(status: OauthDeviceAuthorization::STATUS_DENIED, denied_at: be_present, resource_owner: nil)
    end

    it "returns authorization_pending and slow_down while the user has not approved the code" do
      body = create_device_code

      post oauth_token_path, params: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, client_id: oauth_application.uid, device_code: body["device_code"] }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("error" => "authorization_pending")

      post oauth_token_path, params: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, client_id: oauth_application.uid, device_code: body["device_code"] }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("error" => "slow_down", "interval" => OauthDeviceAuthorization::SLOW_DOWN_INTERVAL.to_i)
    end

    it "does not run the device grant on OAuth token alias routes" do
      body = create_device_code
      device_authorization = OauthDeviceAuthorization.last

      post "/ifttt/v1/oauth2/token", params: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, client_id: oauth_application.uid, device_code: body["device_code"] }

      expect(response).to have_http_status(:bad_request)
      expect(device_authorization.reload).to have_attributes(poll_count: 0, last_polled_at: nil)
    end

    it "returns expired_token for unknown device codes" do
      post oauth_token_path, params: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, client_id: oauth_application.uid, device_code: "unknown-device-code" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("error" => "expired_token")
    end

    it "returns access_denied after the user denies the code" do
      body = create_device_code
      sign_in user

      submit_device_authorization(body["user_code"], decision: "deny")
      post oauth_token_path, params: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, client_id: oauth_application.uid, device_code: body["device_code"] }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("error" => "access_denied")
      expect(Doorkeeper::AccessToken.count).to eq(0)
    end

    it "returns access_denied for denied codes after they expire" do
      body = create_device_code
      sign_in user

      submit_device_authorization(body["user_code"], decision: "deny")
      OauthDeviceAuthorization.last.update!(expires_at: 1.second.ago)

      post oauth_token_path, params: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, client_id: oauth_application.uid, device_code: body["device_code"] }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("error" => "access_denied")
      expect(Doorkeeper::AccessToken.count).to eq(0)
    end

    it "exchanges approved codes when the device application has no browser redirect URI" do
      oauth_application.update_column(:redirect_uri, "")
      body = create_device_code
      sign_in user
      submit_device_authorization(body["user_code"], decision: "approve")

      expect do
        post oauth_token_path, params: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, client_id: oauth_application.uid, device_code: body["device_code"] }
      end.to change { Doorkeeper::AccessToken.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(Doorkeeper::AccessGrant.where(
        application_id: oauth_application.id,
        resource_owner_id: user.id,
        scopes: "view_profile",
        redirect_uri: OauthDeviceAuthorization::DEVICE_REDIRECT_URI
      )).to exist
    end

    it "returns expired_token for expired codes" do
      device_authorization = create(:oauth_device_authorization, oauth_application:, device_code: "expired-device-code", expires_at: 1.second.ago)

      post oauth_token_path, params: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, client_id: oauth_application.uid, device_code: "expired-device-code" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("error" => "expired_token")
      expect(device_authorization.reload).to have_attributes(poll_count: 0, last_polled_at: nil)
    end
  end

  def create_device_code
    post oauth_device_code_path, params: { client_id: oauth_application.uid, scope: "view_profile" }
    response.parsed_body
  end

  def submit_device_authorization(user_code, decision:)
    get oauth_device_authorization_path, params: { user_code: }
    doc = Nokogiri::HTML(response.body)
    authenticity_token_node = doc.at_css("input[name='authenticity_token']") || doc.at_css("meta[name='csrf-token']")
    authenticity_token = authenticity_token_node["value"] || authenticity_token_node["content"]

    post oauth_device_authorization_path, params: { user_code:, decision:, authenticity_token: }
  end

  def stub_vite_layout_helpers
    allow(ViteRuby.instance.manifest).to receive(:resolve_entries).and_return({ stylesheets: ["/vite-test.css"] })
    allow_any_instance_of(ActionView::Base).to receive(:vite_client_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_react_refresh_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag).and_return("")
  end
end
