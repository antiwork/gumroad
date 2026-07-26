# frozen_string_literal: true

require "spec_helper"

describe Throttling, type: :request do
  let(:anonymous_controller) do
    Class.new(ApplicationController) do
      include Throttling

      before_action :test_throttle

      def test_action
        render json: { success: true }
      end

      private
        def test_throttle
          throttle!(key: "test_key", limit: 5, period: 1.hour)
        end
    end
  end

  let(:redis) { $redis }

  before do
    redis.del("test_key")

    Rails.application.routes.draw do
      get "test_throttle", to: "anonymous#test_action"
    end

    stub_const("AnonymousController", anonymous_controller)
  end

  after do
    Rails.application.reload_routes!
  end

  describe "#throttle!" do
    it "allows requests within the limit" do
      get "/test_throttle"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["success"]).to be true
    end

    it "blocks requests when limit is exceeded" do
      # Make 5 requests (the limit)
      5.times do
        get "/test_throttle"
        expect(response).to have_http_status(:ok)
      end

      # The 6th request should be blocked
      get "/test_throttle"

      expect(response).to have_http_status(:too_many_requests)
      expect(JSON.parse(response.body)["error"]).to match(/Rate limit exceeded/)
      expect(response.headers["Retry-After"]).to be_present
    end

    it "reports the seconds remaining in the body as well as the header" do
      6.times { get "/test_throttle" }

      expect(response).to have_http_status(:too_many_requests)
      retry_after = JSON.parse(response.body)["retry_after"]
      expect(retry_after).to be > 0
      expect(retry_after).to eq(response.headers["Retry-After"].to_i)
    end

    it "falls back to the full period when the key's TTL is unavailable" do
      6.times { get "/test_throttle" }
      expect(JSON.parse(response.body)["retry_after"]).to be <= 1.hour.to_i

      # A key with no expiry set reports TTL -1; without a fallback the user would be told to wait a
      # negative number of seconds.
      allow(redis).to receive(:ttl).with("test_key").and_return(-1)
      get "/test_throttle"

      expect(JSON.parse(response.body)["retry_after"]).to eq(1.hour.to_i)
      expect(response.headers["Retry-After"].to_i).to eq(1.hour.to_i)
    end

    it "renders a caller-supplied message instead of the default wording" do
      controller_with_message = Class.new(ApplicationController) do
        include Throttling

        before_action :test_throttle

        def test_action
          render json: { success: true }
        end

        private
          def test_throttle
            throttle!(
              key: "test_key",
              limit: 1,
              period: 1.hour,
              message: ->(retry_after) { "Come back in #{retry_after} seconds." }
            )
          end
      end
      stub_const("AnonymousController", controller_with_message)

      2.times { get "/test_throttle" }

      expect(response).to have_http_status(:too_many_requests)
      expect(JSON.parse(response.body)["error"]).to eq("Come back in #{JSON.parse(response.body)["retry_after"]} seconds.")
    end

    it "sets expiration on first request" do
      get "/test_throttle"

      ttl = redis.ttl("test_key")
      expect(ttl).to be > 0
      expect(ttl).to be <= 3600
    end

    it "does not reset expiration on subsequent requests" do
      get "/test_throttle"
      initial_ttl = redis.ttl("test_key")

      # Manually reduce TTL to simulate time passing
      redis.expire("test_key", initial_ttl - 1)

      # Second request should not reset expiration
      get "/test_throttle"
      second_ttl = redis.ttl("test_key")

      expect(second_ttl).to be < initial_ttl
    end
  end
end
