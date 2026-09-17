# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::MobileMinimumVersionsController do
  let(:user) { create(:user) }
  let(:app) { create(:oauth_application, owner: user) }
  let(:access_token) { create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "account") }

  describe "GET show" do
    context "with valid access token" do
      it "returns the minimum version values from Redis" do
        $redis.set(RedisKey.mobile_minimum_version, "2026.03.01")
        $redis.set(RedisKey.mobile_minimum_update_created_at, "2026-03-12")

        get :show, params: { access_token: access_token.token }

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["minimum_version"]).to eq("2026.03.01")
        expect(body["minimum_update_created_at"]).to eq("2026-03-12")
      end

      it "returns nil values when not set in Redis" do
        get :show, params: { access_token: access_token.token }

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["minimum_version"]).to be_nil
        expect(body["minimum_update_created_at"]).to be_nil
      end

      it "degrades to nil values instead of failing when Redis stalls" do
        $redis.set(RedisKey.mobile_minimum_version, "2026.03.01")
        $redis.set(RedisKey.mobile_minimum_update_created_at, "2026-03-12")
        # Only the two keys this endpoint reads stall; a blanket `$redis.get` stub would also take
        # out the subdomain redirect that runs earlier in the request.
        allow($redis).to receive(:get).and_call_original
        [RedisKey.mobile_minimum_version, RedisKey.mobile_minimum_update_created_at].each do |key|
          allow($redis).to receive(:get).with(key).and_raise(Redis::TimeoutError.new("Waited 1.0 seconds"))
        end

        get :show, params: { access_token: access_token.token }

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["minimum_version"]).to be_nil
        expect(body["minimum_update_created_at"]).to be_nil
      end
    end

    context "without access token" do
      it "returns unauthorized" do
        get :show

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with wrong scope" do
      let(:access_token) { create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "mobile_api") }

      it "returns forbidden" do
        get :show, params: { access_token: access_token.token }

        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
