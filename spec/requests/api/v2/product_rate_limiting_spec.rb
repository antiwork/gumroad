# frozen_string_literal: true

require "spec_helper"

describe "Product API rate limiting", type: :request do
  let(:user) { create(:user) }
  let(:oauth_application) { create(:oauth_application, owner: create(:user)) }
  let(:token) { create("doorkeeper/access_token", application: oauth_application, resource_owner_id: user.id, scopes: "edit_products") }

  before do
    Rack::Attack.cache.store.flushdb
    Rack::Attack.reset!
  end

  describe "POST /api/v2/products" do
    it "throttles product creation after 10 requests per minute" do
      travel_to(Time.current) do
        10.times do
          post "/api/v2/products",
               params: { access_token: token.token, name: "Test", price: 100 },
               headers: { "REMOTE_ADDR" => "203.0.113.1" }
        end

        post "/api/v2/products",
             params: { access_token: token.token, name: "Test", price: 100 },
             headers: { "REMOTE_ADDR" => "203.0.113.1" }
        expect(response).to have_http_status(:too_many_requests)
      end
    end
  end

  describe "PUT /api/v2/products/:id" do
    let(:product) { create(:product, user:) }

    it "throttles product updates after 30 requests per minute" do
      travel_to(Time.current) do
        30.times do
          put "/api/v2/products/#{product.external_id}",
              params: { access_token: token.token, name: "Updated" },
              headers: { "REMOTE_ADDR" => "203.0.113.2" }
        end

        put "/api/v2/products/#{product.external_id}",
            params: { access_token: token.token, name: "Updated" },
            headers: { "REMOTE_ADDR" => "203.0.113.2" }
        expect(response).to have_http_status(:too_many_requests)
      end
    end
  end

  describe "POST /v2/products" do
    it "throttles requests on the api.gumroad.com mount" do
      travel_to(Time.current) do
        10.times do
          post "/v2/products",
               params: { access_token: token.token, name: "Test", price: 100 },
               headers: { "REMOTE_ADDR" => "203.0.113.3" }
        end

        post "/v2/products",
             params: { access_token: token.token, name: "Test", price: 100 },
             headers: { "REMOTE_ADDR" => "203.0.113.3" }
        expect(response).to have_http_status(:too_many_requests)
      end
    end
  end

  describe "PATCH /api/v2/products/:id" do
    let(:product) { create(:product, user:) }

    it "throttles product updates via PATCH after 30 requests per minute" do
      travel_to(Time.current) do
        30.times do
          patch "/api/v2/products/#{product.external_id}",
                params: { access_token: token.token, name: "Updated" },
                headers: { "REMOTE_ADDR" => "203.0.113.6" }
        end

        patch "/api/v2/products/#{product.external_id}",
              params: { access_token: token.token, name: "Updated" },
              headers: { "REMOTE_ADDR" => "203.0.113.6" }
        expect(response).to have_http_status(:too_many_requests)
      end
    end
  end

  describe "format suffix" do
    it "throttles POST /api/v2/products.json" do
      travel_to(Time.current) do
        10.times do
          post "/api/v2/products.json",
               params: { access_token: token.token, name: "Test", price: 100 },
               headers: { "REMOTE_ADDR" => "203.0.113.4" }
        end

        post "/api/v2/products.json",
             params: { access_token: token.token, name: "Test", price: 100 },
             headers: { "REMOTE_ADDR" => "203.0.113.4" }
        expect(response).to have_http_status(:too_many_requests)
      end
    end

    it "throttles PUT /api/v2/products/:id.json" do
      product = create(:product, user:)

      travel_to(Time.current) do
        30.times do
          put "/api/v2/products/#{product.external_id}.json",
              params: { access_token: token.token, name: "Updated" },
              headers: { "REMOTE_ADDR" => "203.0.113.5" }
        end

        put "/api/v2/products/#{product.external_id}.json",
            params: { access_token: token.token, name: "Updated" },
            headers: { "REMOTE_ADDR" => "203.0.113.5" }
        expect(response).to have_http_status(:too_many_requests)
      end
    end
  end
end
