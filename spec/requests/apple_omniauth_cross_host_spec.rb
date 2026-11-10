# frozen_string_literal: true

require "spec_helper"

describe "Apple sign-in across hosts", type: :request do
  let(:signing_key) { OpenSSL::PKey::RSA.new(2048) }
  let!(:user) { create(:user, email: "apple-web@example.com") }

  around do |example|
    previous = OmniAuth.config.test_mode
    previous_forgery = ActionController::Base.allow_forgery_protection
    OmniAuth.config.test_mode = false
    ActionController::Base.allow_forgery_protection = false
    example.run
  ensure
    OmniAuth.config.test_mode = previous
    ActionController::Base.allow_forgery_protection = previous_forgery
  end

  before do
    stub_const("VALID_REQUEST_HOSTS", ["app.example.com", "example.com"])
    client = OAuth2::Client.new("client_id", "fake_secret", site: "https://appleid.apple.com", authorize_url: "/auth/authorize", token_url: "/auth/token")
    allow_any_instance_of(OmniAuth::Strategies::Apple).to receive(:client).and_return(client)
    allow_any_instance_of(OmniAuth::Strategies::Apple).to receive(:build_access_token).and_return(OAuth2::AccessToken.new(client, "access-token"))
    allow_any_instance_of(OmniAuth::Strategies::Apple).to receive(:fetch_jwk!).and_return(JSON::JWK.new(signing_key.public_key))
  end

  def id_token(nonce:)
    JSON::JWT.new(
      iss: "https://appleid.apple.com", aud: APPLE_CLIENT_ID, sub: "apple-web-uid",
      iat: Time.current.to_i, exp: 5.minutes.from_now.to_i,
      email: user.email, email_verified: true, nonce:, nonce_supported: true
    ).sign(signing_key, :RS256).to_s
  end

  it "signs in on the callback host when the login started on a subdomain" do
    host! "app.example.com"
    post "/users/auth/apple", params: { referer: "/library" }
    expect(response.location).to start_with("https://appleid.apple.com/auth/authorize")
    nonce = Rack::Utils.parse_query(URI(response.location).query).fetch("nonce")

    host! "example.com"
    post "/users/auth/apple/callback", params: { code: "authorization-code", id_token: id_token(nonce:) }

    expect(response).to redirect_to("http://example.com/library")
    expect(controller.current_user).to eq(user)
  end

  it "rejects a callback whose nonce does not match the one issued" do
    host! "app.example.com"
    post "/users/auth/apple", params: { referer: "/library" }

    host! "example.com"
    post "/users/auth/apple/callback", params: { code: "authorization-code", id_token: id_token(nonce: "forged-nonce") }

    expect(response.location).not_to end_with("/library")
    expect(user.reload.last_sign_in_at).to be_nil
  end
end
