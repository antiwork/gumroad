# frozen_string_literal: true

require "spec_helper"

describe "Apple OmniAuth strategy cookie-based nonce patch" do
  let(:strategy) { OmniAuth::Strategies::Apple.new(Rails.application, "client_id", "") }

  def sign_cookie(data)
    Rails.application.message_verifier("apple_oauth").generate(
      data, purpose: :apple_oauth, expires_in: APPLE_OAUTH_COOKIE_TTL
    )
  end

  def build_env(path, method: "POST", input: nil, cookies: nil)
    opts = { method: method }
    opts[:input] = input if input
    opts["HTTP_COOKIE"] = cookies if cookies

    env = Rack::MockRequest.env_for(path, **opts)
    env["rack.session"] = {}
    env
  end

  def prepare_strategy(env)
    strategy.instance_variable_set(:@env, env)
    strategy.instance_variable_set(:@cookie_data, nil)
    strategy.instance_variable_set(:@user_info, nil)
  end

  describe "#stored_nonce" do
    it "reads the nonce from the signed cookie" do
      nonce = SecureRandom.urlsafe_base64(32)
      cookie_value = sign_cookie({ "nonce" => nonce, "referer" => "/library" })

      env = build_env(
        "/users/auth/apple/callback",
        cookies: "#{APPLE_OAUTH_COOKIE_NAME}=#{Rack::Utils.escape(cookie_value)}"
      )
      prepare_strategy(env)

      expect(strategy.send(:stored_nonce)).to eq(nonce)
    end

    it "returns nil when cookie is missing" do
      env = build_env("/users/auth/apple/callback")
      prepare_strategy(env)

      expect(strategy.send(:stored_nonce)).to be_nil
    end

    it "returns nil when cookie has been tampered with" do
      env = build_env(
        "/users/auth/apple/callback",
        cookies: "#{APPLE_OAUTH_COOKIE_NAME}=tampered-value"
      )
      prepare_strategy(env)

      expect(strategy.send(:stored_nonce)).to be_nil
    end
  end

  describe "#callback_phase" do
    it "restores omniauth.params from cookie data without the nonce" do
      nonce = SecureRandom.urlsafe_base64(32)
      cookie_value = sign_cookie({ "nonce" => nonce, "referer" => "/library" })

      env = build_env(
        "/users/auth/apple/callback",
        cookies: "#{APPLE_OAUTH_COOKIE_NAME}=#{Rack::Utils.escape(cookie_value)}"
      )
      prepare_strategy(env)

      begin
        strategy.callback_phase
      rescue
        # callback_phase calls super which fails without a real Apple id_token
      end

      expect(env["omniauth.params"]).to eq({ "referer" => "/library" })
    end

    it "parses JSON user param into a hash" do
      user_json = '{"name":{"firstName":"Jane","lastName":"Appleseed"},"email":"jane@example.com"}'
      cookie_value = sign_cookie({ "nonce" => "test" })

      env = build_env(
        "/users/auth/apple/callback",
        input: "user=#{Rack::Utils.escape(user_json)}",
        cookies: "#{APPLE_OAUTH_COOKIE_NAME}=#{Rack::Utils.escape(cookie_value)}"
      )
      Rack::Request.new(env).POST
      prepare_strategy(env)

      begin
        strategy.callback_phase
      rescue
      end

      expect(env["rack.request.form_hash"]["user"]).to be_a(Hash)
      expect(env["rack.request.form_hash"]["user"]["email"]).to eq("jane@example.com")
    end

    it "leaves non-JSON user param as-is" do
      cookie_value = sign_cookie({ "nonce" => "test" })

      env = build_env(
        "/users/auth/apple/callback",
        input: "user=not-json",
        cookies: "#{APPLE_OAUTH_COOKIE_NAME}=#{Rack::Utils.escape(cookie_value)}"
      )
      Rack::Request.new(env).POST
      prepare_strategy(env)

      begin
        strategy.callback_phase
      rescue
      end

      expect(env["rack.request.form_hash"]["user"]).to eq("not-json")
    end
  end

  describe "#request_phase" do
    before do
      # The parent request_phase builds a client_secret from the Apple private
      # key (unavailable in test). Stub the OAuth2 client so super can build
      # the authorize URL without real credentials.
      mock_client = OAuth2::Client.new("client_id", "fake_secret", site: "https://appleid.apple.com", authorize_url: "/auth/authorize", token_url: "/auth/token")
      allow(strategy).to receive(:client).and_return(mock_client)
    end

    it "sets a signed SameSite=None cookie with nonce and referer" do
      env = build_env("/users/auth/apple?referer=/library", method: "GET")
      prepare_strategy(env)

      result = strategy.request_phase

      cookie_header = result[1]["set-cookie"] || result[1]["Set-Cookie"]
      expect(cookie_header).to be_present
      expect(cookie_header).to include(APPLE_OAUTH_COOKIE_NAME)
      expect(cookie_header.downcase).to include("samesite=none")
      expect(cookie_header.downcase).to include("httponly")

      cookie_value = cookie_header.match(/#{APPLE_OAUTH_COOKIE_NAME}=([^;]+)/o)[1]
      decoded = Rails.application.message_verifier("apple_oauth").verified(
        Rack::Utils.unescape(cookie_value), purpose: :apple_oauth
      )
      expect(decoded["nonce"]).to be_present
      expect(decoded["referer"]).to eq("/library")
    end

    it "omits referer from cookie when not provided" do
      env = build_env("/users/auth/apple", method: "GET")
      prepare_strategy(env)

      result = strategy.request_phase

      cookie_header = result[1]["set-cookie"] || result[1]["Set-Cookie"]
      cookie_value = cookie_header.match(/#{APPLE_OAUTH_COOKIE_NAME}=([^;]+)/o)[1]
      decoded = Rails.application.message_verifier("apple_oauth").verified(
        Rack::Utils.unescape(cookie_value), purpose: :apple_oauth
      )
      expect(decoded).not_to have_key("referer")
    end
  end

  describe "#authorize_params" do
    it "includes a nonce parameter" do
      env = build_env("/users/auth/apple", method: "GET")
      prepare_strategy(env)

      params = strategy.authorize_params
      expect(params[:nonce]).to be_present
      expect(params[:nonce].length).to be >= 32
    end

    it "generates a unique nonce each time" do
      env = build_env("/users/auth/apple", method: "GET")
      prepare_strategy(env)

      nonce1 = strategy.authorize_params[:nonce]

      strategy.instance_variable_set(:@apple_oauth_nonce, nil)
      nonce2 = strategy.authorize_params[:nonce]

      expect(nonce1).not_to eq(nonce2)
    end
  end

  describe "#user_info" do
    it "returns hash user data as-is from form-encoded request params" do
      env = build_env(
        "/users/auth/apple/callback",
        input: "user%5BfirstName%5D=Jane&user%5BlastName%5D=Doe"
      )
      Rack::Request.new(env).POST
      prepare_strategy(env)

      info = strategy.send(:user_info)
      expect(info).to be_a(Hash)
      expect(info["firstName"]).to eq("Jane")
    end

    it "parses a JSON string user param without callback_phase form_hash rewrite" do
      user_json = '{"name":{"firstName":"Jane","lastName":"Appleseed"},"email":"jane@example.com"}'
      env = build_env(
        "/users/auth/apple/callback",
        input: "user=#{Rack::Utils.escape(user_json)}"
      )
      Rack::Request.new(env).POST
      prepare_strategy(env)

      info = strategy.send(:user_info)
      expect(info).to be_a(Hash)
      expect(info["email"]).to eq("jane@example.com")
      expect(info.dig("name", "firstName")).to eq("Jane")
    end

    it "returns empty hash when no user data is present" do
      env = build_env("/users/auth/apple/callback")
      prepare_strategy(env)

      expect(strategy.send(:user_info)).to eq({})
    end
  end
end
