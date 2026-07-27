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

  describe "throttles with params-based discriminators when the request body is malformed multipart" do
    # Scanners POST `Content-Type: multipart/form-data` with an empty body and no
    # Content-Length. Parsing that body raises Rack::Multipart::EmptyContentError,
    # and any throttle block that touches req.params would previously crash the
    # middleware with a 500 instead of letting the request through to the app.
    def malformed_multipart_request(path)
      env = Rack::MockRequest.env_for(
        path,
        method: "POST",
        "CONTENT_TYPE" => "multipart/form-data; boundary=AaB03x",
        "HTTP_CF_CONNECTING_IP" => "203.0.113.90",
        input: ""
      )
      # No Content-Length header — this is what makes the multipart parser raise
      # EmptyContentError instead of skipping the body.
      env.delete("CONTENT_LENGTH")
      Rack::Attack::Request.new(env)
    end

    before { reset_rack_attack! }
    after { reset_rack_attack! }

    it "does not raise for a params-keyed throttle path (/follow)" do
      expect do
        Rack::Attack.configuration.throttled?(malformed_multipart_request("/follow"))
      end.not_to raise_error
    end

    it "does not raise for the login throttle path (/login.json)" do
      expect do
        Rack::Attack.configuration.throttled?(malformed_multipart_request("/login.json"))
      end.not_to raise_error
    end

    it "does not raise for the sales API pagination throttle path (/api/v2/sales)" do
      expect do
        Rack::Attack.configuration.throttled?(malformed_multipart_request("/api/v2/sales"))
      end.not_to raise_error
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

  describe "POST /settings/passkeys registration throttles" do
    before { reset_rack_attack! }
    after { reset_rack_attack! }

    it "shares one registration-options throttle bucket across formatted route variants" do
      user = create(:user)

      request_for = lambda do |path|
        env = Rack::MockRequest.env_for(path, method: "POST", input: "", "HTTP_CF_CONNECTING_IP" => "203.0.113.80")
        env["warden"] = double(user:)
        Rack::Attack::Request.new(env)
      end

      travel_to(Time.current) do
        10.times do |i|
          request = request_for.call(i.even? ? "/settings/passkeys/registration_options" : "/settings/passkeys/registration_options.json")

          expect(Rack::Attack.configuration.throttled?(request)).to be(false), "request #{i + 1} unexpectedly throttled"
        end

        expect(Rack::Attack.configuration.throttled?(request_for.call("/settings/passkeys/registration_options.xml"))).to be(true)
      end
    end

    it "shares one credential-create throttle bucket across formatted route variants" do
      user = create(:user)

      request_for = lambda do |path|
        env = Rack::MockRequest.env_for(path, method: "POST", input: "", "HTTP_CF_CONNECTING_IP" => "203.0.113.81")
        env["warden"] = double(user:)
        Rack::Attack::Request.new(env)
      end

      travel_to(Time.current) do
        10.times do |i|
          request = request_for.call(i.even? ? "/settings/passkeys" : "/settings/passkeys.json")

          expect(Rack::Attack.configuration.throttled?(request)).to be(false), "request #{i + 1} unexpectedly throttled"
        end

        expect(Rack::Attack.configuration.throttled?(request_for.call("/settings/passkeys.xml"))).to be(true)
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

  describe "PUT /api/v2/user/custom_html per-token throttle" do
    before { reset_rack_attack! }
    after { reset_rack_attack! }

    it "throttles past 30 PUTs/min per token even when the source IP rotates" do
      user = create(:user)
      app = create(:oauth_application, owner: create(:user))
      token = create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "edit_profile").token
      Feature.activate_user(:custom_html_pages, user)

      travel_to(Time.current) do
        30.times do |i|
          put "/api/v2/user/custom_html",
              params: { access_token: token, custom_html: "<p>#{i}</p>" },
              headers: { "HTTP_CF_CONNECTING_IP" => "10.2.0.#{i + 1}" }
          expect(response.status).not_to eq(429), "request #{i + 1} unexpectedly throttled"
        end

        put "/api/v2/user/custom_html",
            params: { access_token: token, custom_html: "<p>over</p>" },
            headers: { "HTTP_CF_CONNECTING_IP" => "10.2.0.99" }

        expect(response.status).to eq(429)
      end
    end
  end

  describe "POST /api/v2/user/preview_custom_html per-token throttle" do
    before { reset_rack_attack! }
    after { reset_rack_attack! }

    it "throttles past 60 preview requests/min per token even when the source IP rotates" do
      user = create(:user)
      app = create(:oauth_application, owner: create(:user))
      token = create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "edit_profile").token
      Feature.activate_user(:custom_html_pages, user)

      travel_to(Time.current) do
        60.times do |i|
          post "/api/v2/user/preview_custom_html",
               params: { access_token: token, custom_html: "<p>#{i}</p>" },
               headers: { "HTTP_CF_CONNECTING_IP" => "10.3.0.#{i + 1}" }
          expect(response.status).not_to eq(429), "request #{i + 1} unexpectedly throttled"
        end

        post "/api/v2/user/preview_custom_html",
             params: { access_token: token, custom_html: "<p>over</p>" },
             headers: { "HTTP_CF_CONNECTING_IP" => "10.3.0.99" }

        expect(response.status).to eq(429)
      end
    end
  end

  describe "POST /api/v2/media per-token throttle" do
    before { reset_rack_attack! }
    after { reset_rack_attack! }

    it "throttles past 20 uploads/10min per token even when the source IP rotates" do
      user = create(:user)
      app = create(:oauth_application, owner: create(:user))
      token = create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "edit_profile").token

      # The controller would run CreatePublicMediaService (which downloads the URL); the throttle
      # fires before the app anyway, but stub the service so under-limit requests stay cheap.
      allow(CreatePublicMediaService).to receive(:new).and_return(
        instance_double(CreatePublicMediaService, process: CreatePublicMediaService::Result.new(success: false, error_message: "stubbed"))
      )

      travel_to(Time.current) do
        20.times do |i|
          post "/api/v2/media",
               params: { access_token: token, url: "https://example.com/#{i}.png" },
               headers: { "HTTP_CF_CONNECTING_IP" => "10.4.0.#{i + 1}" }
          expect(response.status).not_to eq(429), "request #{i + 1} unexpectedly throttled"
        end

        post "/api/v2/media",
             params: { access_token: token, url: "https://example.com/over.png" },
             headers: { "HTTP_CF_CONNECTING_IP" => "10.4.0.99" }

        expect(response.status).to eq(429)
      end
    end
  end

  describe "POST /orders checkout throttles" do
    # Real free products: OrdersController#validate_order_request looks each line item's
    # permalink up before the request reaches the app, and a nonexistent permalink makes
    # the CAPTCHA-skip check blow up on nil — which would mask what these specs measure.
    let!(:product) { create(:product, price_cents: 0) }
    let!(:other_product) { create(:product, price_cents: 0) }

    before { reset_rack_attack! }
    after { reset_rack_attack! }

    def checkout(path: "/orders", permalinks: [product.unique_permalink], ip:, uid: "u1", perceived_price_cents: "0")
      line_items = permalinks.each_with_index.map do |permalink, i|
        { uid: "#{uid}-#{i}", permalink:, perceived_price_cents: }
      end
      post path, params: { line_items: }, headers: { "HTTP_CF_CONNECTING_IP" => ip }
    end

    # The route these throttles must cover. Guards against the regression this replaced:
    # the old rules pointed at "/purchases", which has no POST route, so checkout was
    # entirely unthrottled. If checkout ever moves again, this fails loudly.
    it "has no POST route for the legacy /purchases checkout path" do
      expect { Rails.application.routes.recognize_path("/purchases", method: :post) }
        .to raise_error(ActionController::RoutingError)
    end

    it "throttles a single IP past 40 order submissions/min" do
      travel_to(Time.current) do
        40.times do |i|
          checkout(ip: "10.5.0.1", uid: "u#{i}")
          expect(response.status).not_to eq(429), "request #{i + 1} unexpectedly throttled"
        end

        checkout(ip: "10.5.0.1", uid: "over")
        expect(response.status).to eq(429)
      end
    end

    context "per-product free-checkout cap" do
      # Exercising the real 600/hour cap would mean issuing 600 checkouts per example, so
      # stub the limit down. The throttle reads it per request precisely so this works.
      before { stub_const("Rack::Attack::CHECKOUT_FREE_PRODUCT_HOURLY_LIMIT", 5) }

      it "throttles one product past the cap even when the source IP rotates" do
        # This is the case the per-IP rules miss: a residential-proxy pool keeps every
        # individual IP well under its budget while hammering one product's checkout,
        # which is what let a free product blast receipts to a scraped address list.
        travel_to(Time.current) do
          5.times do |i|
            checkout(ip: "10.6.0.#{i + 1}", uid: "u#{i}")
            expect(response.status).not_to eq(429), "request #{i + 1} unexpectedly throttled"
          end

          checkout(ip: "10.7.0.1", uid: "over")
          expect(response.status).to eq(429)

          # The cap is per product, so a different product still gets its own budget.
          checkout(ip: "10.7.0.2", permalinks: [other_product.unique_permalink], uid: "other")
          expect(response.status).not_to eq(429)
        end
      end

      it "shares one bucket across formatted route variants and /orders/prepare" do
        travel_to(Time.current) do
          2.times do |i|
            checkout(path: "/orders.json", ip: "10.8.0.#{i + 1}", uid: "j#{i}")
            expect(response.status).not_to eq(429), "json request #{i + 1} unexpectedly throttled"
          end

          3.times do |i|
            checkout(path: "/orders/prepare", ip: "10.9.0.#{i + 1}", uid: "p#{i}")
            expect(response.status).not_to eq(429), "prepare request #{i + 1} unexpectedly throttled"
          end

          checkout(ip: "10.9.9.9", uid: "over")
          expect(response.status).to eq(429)
        end
      end

      # Every product in the cart is charged, so neither ordering hides the abused one.
      # The padding product rotates each request, which is the shape that would slip past
      # a cap keyed on only one line item.
      [:first, :last].each do |position|
        it "charges the abused product when it is the #{position} item in a mixed cart" do
          travel_to(Time.current) do
            5.times do |i|
              padding = create(:product, price_cents: 0).unique_permalink
              target = product.unique_permalink
              permalinks = position == :first ? [target, padding] : [padding, target]
              checkout(ip: "10.10.#{position == :first ? 0 : 1}.#{i + 1}", permalinks:, uid: "a#{i}")
              expect(response.status).not_to eq(429), "request #{i + 1} unexpectedly throttled"
            end

            fresh = create(:product, price_cents: 0).unique_permalink
            permalinks = position == :first ? [product.unique_permalink, fresh] : [fresh, product.unique_permalink]
            checkout(ip: "10.11.0.1", permalinks:, uid: "over")
            expect(response.status).to eq(429)
          end
        end
      end

      # The cap is a budget shared across every source IP, so a stranger can spend it on a
      # seller's behalf. Scoping it to free line items is what keeps that from ever costing
      # someone a real sale: a paid checkout never consults this counter at all.
      it "does not count paid line items, so a paid purchase can't be throttled out by others" do
        travel_to(Time.current) do
          20.times do |i|
            checkout(ip: "10.13.0.#{i + 1}", uid: "paid#{i}", perceived_price_cents: "500")
            expect(response.status).not_to eq(429), "paid request #{i + 1} unexpectedly throttled"
          end
        end
      end

      # ...and free traffic against the product does not spend a paid buyer's budget either,
      # because the two never share a counter.
      it "leaves paid checkout of the same product working after the free budget is spent" do
        travel_to(Time.current) do
          6.times { |i| checkout(ip: "10.14.0.#{i + 1}", uid: "free#{i}") }
          expect(response.status).to eq(429)

          checkout(ip: "10.14.9.9", uid: "paid", perceived_price_cents: "500")
          expect(response.status).not_to eq(429)
        end
      end
    end

    # Malformed `line_items` must not make the THROTTLE raise — the per-product key
    # extractor reads request params, so a bad shape there would take down the middleware
    # for every request on the path rather than just the bad one.
    #
    # Verified against unmodified main: all three shapes below already raise inside
    # `OrdersController` before this change (`line_items` is treated as an Array of Hashes
    # without checking, so a String or bare Hash blows up — NoMethodError for some shapes,
    # TypeError for others). That is a pre-existing controller bug, not something introduced
    # here, and fixing it is out of scope. So assert on WHERE the failure comes from: it must
    # never originate in the rate limiter.
    it "does not make the throttle raise when line_items is absent or malformed" do
      [
        { line_items: "not-an-array" },
        { line_items: ["a string, not a hash"] },
        { email: "buyer@example.com" },
      ].each_with_index do |params, i|
        raised = nil
        begin
          post "/orders", params:, headers: { "HTTP_CF_CONNECTING_IP" => "10.12.0.#{i + 1}" }
        rescue StandardError => e
          raised = e
        end

        if raised
          expect(raised.backtrace.join("\n")).not_to include("rack_attack.rb"),
                                                     "params #{params.inspect} raised from the rate limiter: #{raised.class}: #{raised.message}"
        else
          expect(response.status).not_to eq(429)
        end
      end
    end

    # The throttle key extractor in isolation, so the pre-existing controller crash above
    # can't hide a regression in it. These are the shapes that reach it in production.
    describe "free-checkout permalink extraction" do
      def free_permalinks_for(params, json: false)
        env = if json
          Rack::MockRequest.env_for("/orders", method: "POST", input: params.to_json,
                                               "CONTENT_TYPE" => "application/json")
        else
          Rack::MockRequest.env_for("/orders", method: "POST", params:)
        end
        Rack::Attack.free_checkout_permalinks(Rack::Attack::Request.new(env))
      end

      def free_item(permalink, price: "0")
        { "permalink" => permalink, "perceived_price_cents" => price }
      end

      # This is the case that matters most: the real checkout frontend posts a JSON body
      # (`utils/request.ts`), and `Rack::Request#params` does not parse JSON — so reading
      # `req.params` here would key every genuine checkout as nil and the cap would never
      # fire at all. Specs that post form-encoded params (the rspec default) pass either
      # way, so without this example the throttle could ship dead.
      it "reads the permalink from a JSON body, as the checkout frontend sends it" do
        expect(free_permalinks_for({ "line_items" => [free_item("abc")] }, json: true)).to eq(["abc"])
      end

      it "returns every free permalink in a cart, not just the first" do
        expect(free_permalinks_for({ "line_items" => [free_item("abc"), free_item("def")] })).to eq(%w[abc def])
      end

      it "ignores paid line items" do
        items = [free_item("abc"), free_item("paid", price: "500")]
        expect(free_permalinks_for({ "line_items" => items })).to eq(["abc"])
        expect(free_permalinks_for({ "line_items" => [free_item("paid", price: "500")] })).to eq([])
      end

      it "counts a repeated permalink once per request" do
        expect(free_permalinks_for({ "line_items" => [free_item("abc"), free_item("abc")] })).to eq(["abc"])
      end

      it "handles line_items arriving as a hash of indexed items" do
        expect(free_permalinks_for({ "line_items" => { "0" => free_item("abc") } })).to eq(["abc"])
      end

      it "returns nothing rather than raising for malformed or absent line_items" do
        expect(free_permalinks_for({ "line_items" => "not-an-array" })).to eq([])
        expect(free_permalinks_for({ "line_items" => ["a string, not a hash"] })).to eq([])
        expect(free_permalinks_for({ "line_items" => [free_item("")] })).to eq([])
        expect(free_permalinks_for({ "line_items" => [{ "permalink" => "abc" }] })).to eq([])
        expect(free_permalinks_for({ "email" => "buyer@example.com" })).to eq([])
        expect(free_permalinks_for({ "line_items" => "not-an-array" }, json: true)).to eq([])
        expect(free_permalinks_for({ "line_items" => ["a string, not a hash"] }, json: true)).to eq([])
      end

      it "does not raise on a malformed JSON body" do
        env = Rack::MockRequest.env_for("/orders", method: "POST", input: "{not json",
                                                   "CONTENT_TYPE" => "application/json")
        expect { Rack::Attack.free_checkout_permalinks(Rack::Attack::Request.new(env)) }
          .not_to raise_error
      end

      # json_params reads the request body; if it did not rewind, the app would see an
      # already-consumed body and checkout would break for every request.
      it "leaves the request body readable for the app" do
        body = { "line_items" => [free_item("abc")] }.to_json
        env = Rack::MockRequest.env_for("/orders", method: "POST", input: body,
                                                   "CONTENT_TYPE" => "application/json")
        Rack::Attack.free_checkout_permalinks(Rack::Attack::Request.new(env))
        expect(env["rack.input"].read).to eq(body)
      end

      # The registered throttle only blocks once a bucket is already over budget, and its
      # discriminator names which product ran out — checked directly here so the
      # request-level examples above aren't the only thing standing between a silent
      # rewrite of the counting and a dead cap.
      it "names the over-budget product only once its bucket is spent" do
        stub_const("Rack::Attack::CHECKOUT_FREE_PRODUCT_HOURLY_LIMIT", 2)
        env = Rack::MockRequest.env_for("/orders", method: "POST", input: { "line_items" => [free_item("abc")] }.to_json,
                                                   "CONTENT_TYPE" => "application/json")
        req = -> { Rack::Attack::Request.new(env.dup) }

        expect(Rack::Attack.exceeded_free_checkout_permalink(req.call)).to be_nil
        expect(Rack::Attack.exceeded_free_checkout_permalink(req.call)).to be_nil
        expect(Rack::Attack.exceeded_free_checkout_permalink(req.call)).to eq("abc")
      end
    end
  end
end
