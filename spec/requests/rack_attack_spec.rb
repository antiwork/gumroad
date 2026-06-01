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
