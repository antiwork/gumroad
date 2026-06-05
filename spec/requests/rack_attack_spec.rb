# frozen_string_literal: true

require "spec_helper"

describe "Rack::Attack throttle", type: :request do
  def reset_rack_attack!
    Rack::Attack.cache.store.flushdb
    Rack::Attack.reset!
  end

  before do
    allow_any_instance_of(ActionDispatch::Request).to receive(:host).and_return(VALID_REQUEST_HOSTS.first)
  end

  describe "forgot_password throttle with malformed JSON params" do
    it "does not raise TypeError when json_params contain non-Hash nested values" do
      post "/forgot_password.json",
           params: { user: "not-a-hash" }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }

      expect(response.status).not_to eq(500)
    end
  end

  describe "POST /oauth/token device grant throttle with malformed params" do
    it "does not raise when the params parser rejects malformed form params" do
      post "/oauth/token",
           params: "grant_type=#{Rack::Utils.escape(OauthDeviceAuthorization::GRANT_TYPE)}&grant_type[bad]=1",
           headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }

      expect(response.status).not_to eq(500)
    end

    it "throttles JSON device grant polls by IP and device code" do
      reset_rack_attack!

      travel_to(Time.current) do
        120.times do |i|
          request = Rack::Attack::Request.new(
            Rack::MockRequest.env_for(
              i.even? ? "/oauth/token" : "/oauth/token.json",
              method: "POST",
              input: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, device_code: "json-device-code" }.to_json,
              "CONTENT_TYPE" => "application/json",
              "HTTP_CF_CONNECTING_IP" => "203.0.113.40"
            )
          )

          expect(Rack::Attack.configuration.throttled?(request)).to be(false), "request #{i + 1} unexpectedly throttled"
        end

        request = Rack::Attack::Request.new(
          Rack::MockRequest.env_for(
            "/oauth/token.json",
            method: "POST",
            input: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, device_code: "json-device-code" }.to_json,
            "CONTENT_TYPE" => "application/json",
            "HTTP_CF_CONNECTING_IP" => "203.0.113.40"
          )
        )

        expect(Rack::Attack.configuration.throttled?(request)).to be(true)
      end
    ensure
      reset_rack_attack!
    end

    it "throttles JSON content-type device grant polls with query params" do
      reset_rack_attack!

      query = "grant_type=#{Rack::Utils.escape(OauthDeviceAuthorization::GRANT_TYPE)}&device_code=query-device-code"

      travel_to(Time.current) do
        120.times do |i|
          request = Rack::Attack::Request.new(
            Rack::MockRequest.env_for(
              "/oauth/token?#{query}",
              method: "POST",
              input: {}.to_json,
              "CONTENT_TYPE" => "application/json",
              "HTTP_CF_CONNECTING_IP" => "203.0.113.50"
            )
          )

          expect(Rack::Attack.configuration.throttled?(request)).to be(false), "request #{i + 1} unexpectedly throttled"
        end

        request = Rack::Attack::Request.new(
          Rack::MockRequest.env_for(
            "/oauth/token?#{query}",
            method: "POST",
            input: {}.to_json,
            "CONTENT_TYPE" => "application/json",
            "HTTP_CF_CONNECTING_IP" => "203.0.113.50"
          )
        )

        expect(Rack::Attack.configuration.throttled?(request)).to be(true)
      end
    ensure
      reset_rack_attack!
    end

    it "uses query params over JSON body params for the device code throttle key" do
      reset_rack_attack!

      query = "grant_type=#{Rack::Utils.escape(OauthDeviceAuthorization::GRANT_TYPE)}&device_code=query-device-code"

      travel_to(Time.current) do
        120.times do |i|
          request = Rack::Attack::Request.new(
            Rack::MockRequest.env_for(
              "/oauth/token?#{query}",
              method: "POST",
              input: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, device_code: "body-device-code-#{i}" }.to_json,
              "CONTENT_TYPE" => "application/json",
              "HTTP_CF_CONNECTING_IP" => "203.0.113.60"
            )
          )

          expect(Rack::Attack.configuration.throttled?(request)).to be(false), "request #{i + 1} unexpectedly throttled"
        end

        request = Rack::Attack::Request.new(
          Rack::MockRequest.env_for(
            "/oauth/token?#{query}",
            method: "POST",
            input: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, device_code: "body-device-code-over" }.to_json,
            "CONTENT_TYPE" => "application/json",
            "HTTP_CF_CONNECTING_IP" => "203.0.113.60"
          )
        )

        expect(Rack::Attack.configuration.throttled?(request)).to be(true)
      end
    ensure
      reset_rack_attack!
    end

    it "uses query params over form body params for the device code throttle key" do
      reset_rack_attack!

      query = "grant_type=#{Rack::Utils.escape(OauthDeviceAuthorization::GRANT_TYPE)}&device_code=query-device-code"

      travel_to(Time.current) do
        120.times do |i|
          request = Rack::Attack::Request.new(
            Rack::MockRequest.env_for(
              "/oauth/token?#{query}",
              method: "POST",
              input: "grant_type=#{Rack::Utils.escape(OauthDeviceAuthorization::GRANT_TYPE)}&device_code=body-device-code-#{i}",
              "CONTENT_TYPE" => "application/x-www-form-urlencoded",
              "HTTP_CF_CONNECTING_IP" => "203.0.113.70"
            )
          )

          expect(Rack::Attack.configuration.throttled?(request)).to be(false), "request #{i + 1} unexpectedly throttled"
        end

        request = Rack::Attack::Request.new(
          Rack::MockRequest.env_for(
            "/oauth/token?#{query}",
            method: "POST",
            input: "grant_type=#{Rack::Utils.escape(OauthDeviceAuthorization::GRANT_TYPE)}&device_code=body-device-code-over",
            "CONTENT_TYPE" => "application/x-www-form-urlencoded",
            "HTTP_CF_CONNECTING_IP" => "203.0.113.70"
          )
        )

        expect(Rack::Attack.configuration.throttled?(request)).to be(true)
      end
    ensure
      reset_rack_attack!
    end
  end

  describe "POST /oauth/device/code issuance throttle" do
    before { reset_rack_attack! }
    after { reset_rack_attack! }

    it "shares one throttle bucket across formatted route variants" do
      travel_to(Time.current) do
        20.times do |i|
          request = Rack::Attack::Request.new(
            Rack::MockRequest.env_for(
              i.even? ? "/oauth/device/code" : "/oauth/device/code.json",
              method: "POST",
              input: "",
              "HTTP_CF_CONNECTING_IP" => "203.0.113.30"
            )
          )

          expect(Rack::Attack.configuration.throttled?(request)).to be(false), "request #{i + 1} unexpectedly throttled"
        end

        request = Rack::Attack::Request.new(
          Rack::MockRequest.env_for(
            "/oauth/device/code.xml",
            method: "POST",
            input: "",
            "HTTP_CF_CONNECTING_IP" => "203.0.113.30"
          )
        )

        expect(Rack::Attack.configuration.throttled?(request)).to be(true)
      end
    end
  end

  describe "GET /oauth/device user code lookup throttle" do
    before { reset_rack_attack! }
    after { reset_rack_attack! }

    it "throttles repeated lookup attempts from the same IP" do
      travel_to(Time.current) do
        30.times do |i|
          request = Rack::Attack::Request.new(
            Rack::MockRequest.env_for(
              i.even? ? "/oauth/device?user_code=GRD-TEST-#{i.to_s.rjust(4, "0")}" : "/oauth/device.json?user_code=GRD-TEST-#{i.to_s.rjust(4, "0")}",
              method: i.even? ? "GET" : "HEAD",
              input: "",
              "HTTP_CF_CONNECTING_IP" => "203.0.113.10"
            )
          )

          expect(Rack::Attack.configuration.throttled?(request)).to be(false), "request #{i + 1} unexpectedly throttled"
        end

        request = Rack::Attack::Request.new(
          Rack::MockRequest.env_for(
            "/oauth/device.json?user_code=GRD-TEST-OVER",
            method: "HEAD",
            input: "",
            "HTTP_CF_CONNECTING_IP" => "203.0.113.10"
          )
        )

        expect(Rack::Attack.configuration.throttled?(request)).to be(true)
      end
    end
  end

  describe "POST /oauth/device authorization decision throttle" do
    before { reset_rack_attack! }
    after { reset_rack_attack! }

    it "shares one throttle bucket across formatted route variants" do
      travel_to(Time.current) do
        10.times do |i|
          request = Rack::Attack::Request.new(
            Rack::MockRequest.env_for(
              i.even? ? "/oauth/device" : "/oauth/device.json",
              method: "POST",
              input: "",
              "HTTP_CF_CONNECTING_IP" => "203.0.113.20"
            )
          )

          expect(Rack::Attack.configuration.throttled?(request)).to be(false), "request #{i + 1} unexpectedly throttled"
        end

        request = Rack::Attack::Request.new(
          Rack::MockRequest.env_for(
            "/oauth/device.xml",
            method: "POST",
            input: "",
            "HTTP_CF_CONNECTING_IP" => "203.0.113.20"
          )
        )

        expect(Rack::Attack.configuration.throttled?(request)).to be(true)
      end
    end
  end

  describe "PUT /api/v2/products/:id per-token throttle" do
    before { reset_rack_attack! }
    after { reset_rack_attack! }

    it "throttles past 30 PUTs/min per token even when the source IP rotates" do
      user = create(:user)
      product = create(:product, user: user)
      app = create(:oauth_application, owner: create(:user))
      token = create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "edit_products").token
      Feature.activate_user(:custom_html_pages, user)

      travel_to(Time.current) do
        30.times do |i|
          put "/api/v2/products/#{product.external_id}",
              params: { access_token: token, custom_html: "<p>#{i}</p>" },
              headers: { "HTTP_CF_CONNECTING_IP" => "10.0.0.#{i + 1}" }
          expect(response.status).not_to eq(429), "request #{i + 1} unexpectedly throttled"
        end

        put "/api/v2/products/#{product.external_id}",
            params: { access_token: token, custom_html: "<p>over</p>" },
            headers: { "HTTP_CF_CONNECTING_IP" => "10.0.0.99" }

        expect(response.status).to eq(429)
      end
    end
  end

  describe "POST /api/v2/products/:id/preview_custom_html per-token throttle" do
    before { reset_rack_attack! }
    after { reset_rack_attack! }

    it "throttles past 60 preview requests/min per token even when the source IP rotates" do
      user = create(:user)
      product = create(:product, user: user)
      app = create(:oauth_application, owner: create(:user))
      token = create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "edit_products").token
      Feature.activate_user(:custom_html_pages, user)

      travel_to(Time.current) do
        60.times do |i|
          post "/api/v2/products/#{product.external_id}/preview_custom_html",
               params: { access_token: token, custom_html: "<p>#{i}</p>" },
               headers: { "HTTP_CF_CONNECTING_IP" => "10.1.0.#{i + 1}" }
          expect(response.status).not_to eq(429), "request #{i + 1} unexpectedly throttled"
        end

        post "/api/v2/products/#{product.external_id}/preview_custom_html",
             params: { access_token: token, custom_html: "<p>over</p>" },
             headers: { "HTTP_CF_CONNECTING_IP" => "10.1.0.99" }

        expect(response.status).to eq(429)
      end
    end
  end
end
