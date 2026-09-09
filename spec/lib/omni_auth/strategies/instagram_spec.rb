# frozen_string_literal: true

require "spec_helper"

describe OmniAuth::Strategies::Instagram do
  let(:app) { ->(_env) { [200, {}, ["ok"]] } }
  let(:strategy) { described_class.new(app, "app-id", "app-secret") }

  def assign_env(user)
    warden = instance_double(Warden::Proxy, user:)
    strategy.instance_variable_set(:@env, { "warden" => warden })
  end

  describe "#instagram_connect_enabled?" do
    it "is false when the flag is off" do
      assign_env(create(:user))

      expect(strategy.send(:instagram_connect_enabled?)).to eq(false)
    end

    it "is true when the signed-in user has the flag" do
      user = create(:user)
      Feature.activate_user(:instagram_connect, user)
      assign_env(user)

      expect(strategy.send(:instagram_connect_enabled?)).to eq(true)
    end

    it "uses the impersonated seller as the flag actor" do
      admin = create(:admin_user)
      seller = create(:user)
      Feature.activate_user(:instagram_connect, seller)
      allow($redis).to receive(:get).with(RedisKey.impersonated_user(admin.id)).and_return(seller.id.to_s)
      assign_env(admin)

      expect(strategy.send(:instagram_connect_enabled?)).to eq(true)
    end
  end

  describe "#request_phase" do
    it "redirects to Social connections when the flag is off for a signed-in user" do
      assign_env(create(:user))

      status, headers, = strategy.request_phase

      expect(status).to eq(302)
      expect(headers["Location"]).to eq("/settings/social_connections")
    end

    it "redirects to login when the flag is off and no user is signed in" do
      assign_env(nil)

      status, headers, = strategy.request_phase

      expect(status).to eq(302)
      expect(headers["Location"]).to eq("/login")
    end
  end

  describe "#callback_phase" do
    let(:session) { {} }
    let(:callback_strategy) { described_class.new(app, "app-id", "app-secret") }
    let(:redirect_uri) { "https://example.com/users/auth/instagram/callback" }
    let(:token_request) do
      stub_request(:post, "https://api.instagram.com/oauth/access_token")
        .to_return(
          headers: { "Content-Type" => "application/json" },
          body: { access_token: "instagram-token", user_id: "123" }.to_json,
        )
    end

    before do
      [strategy, callback_strategy].each do |instance|
        allow(instance).to receive(:full_host).and_return("https://example.com")
        allow(instance).to receive(:instagram_connect_enabled?).and_return(true)
        instance.options.callback_path = "/users/auth/instagram/callback"
      end
      strategy.instance_variable_set(:@env, Rack::MockRequest.env_for("https://example.com/users/auth/instagram").merge("rack.session" => session))
      token_request
    end

    it "validates state and uses the authorization redirect URI without callback query parameters" do
      _, headers, = strategy.request_phase
      authorize_params = Rack::Utils.parse_query(URI(headers["Location"]).query)
      expect(authorize_params.fetch("redirect_uri")).to eq(redirect_uri)
      state = authorize_params.fetch("state")
      expect(state).to be_present
      expect(session["omniauth.state"]).to eq(state)

      callback_env = Rack::MockRequest.env_for("#{redirect_uri}?#{Rack::Utils.build_query(code: "authorization-code", state:)}").merge("rack.session" => session)
      callback_strategy.instance_variable_set(:@env, callback_env)

      expect(callback_strategy.callback_phase.first).to eq(200)
      expect(callback_env["omniauth.auth"].uid).to eq("123")
      expect(session).not_to have_key("omniauth.state")
      expect(token_request.with(body: hash_including("code" => "authorization-code", "redirect_uri" => redirect_uri))).to have_been_requested.once
    end

    [nil, "mismatched-state"].each do |state|
      it "rejects #{state.nil? ? 'missing' : 'mismatched'} state before token exchange" do
        strategy.request_phase
        callback_env = Rack::MockRequest.env_for("#{redirect_uri}?#{Rack::Utils.build_query(code: "authorization-code", state:)}").merge("rack.session" => session)
        callback_strategy.instance_variable_set(:@env, callback_env)
        allow(OmniAuth.config).to receive(:on_failure).and_return(->(_env) { [401, {}, []] })

        expect(callback_strategy.callback_phase.first).to eq(401)
        expect(callback_env["omniauth.error.type"]).to eq(:csrf_detected)
        expect(callback_env).not_to have_key("omniauth.auth")
        expect(token_request).not_to have_been_requested
      end
    end
  end

  it "uses the current Instagram Login parameters" do
    expect(strategy.options.authorize_params.to_h).to include(
      "enable_fb_login" => "false",
      "force_reauth" => "true",
    )
  end

  it "unwraps Instagram's token response" do
    access_token_class = strategy.options.client_options[:access_token_class]

    token = access_token_class.from_hash(
      strategy.client,
      "data" => [{ "access_token" => "instagram-token", "user_id" => "123" }],
    )

    expect(token.token).to eq("instagram-token")
    expect(token.params["user_id"]).to eq("123")
  end
end
