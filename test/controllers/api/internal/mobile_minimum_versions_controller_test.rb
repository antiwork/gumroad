# frozen_string_literal: true

require "test_helper"

class ApiInternalMobileMinimumVersionsControllerTest < ActionController::TestCase
  self.described_class = Api::Internal::MobileMinimumVersionsController
  tests Api::Internal::MobileMinimumVersionsController



  context_ Api::Internal::MobileMinimumVersionsController do
    let(:user) { create(:user) }
    let(:app) { create(:oauth_application, owner: user) }
    let(:access_token) { create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "account") }

  context_ "GET show" do
  context_ "with valid access token" do
  test "returns the minimum version values from Redis" do
          $redis.set(RedisKey.mobile_minimum_version, "2026.03.01")
          $redis.set(RedisKey.mobile_minimum_update_created_at, "2026-03-12")

          get :show, params: { access_token: access_token.token }

          expect(response).to be_successful
          body = response.parsed_body
          expect(body["minimum_version"]).to eq("2026.03.01")
          expect(body["minimum_update_created_at"]).to eq("2026-03-12")
        end

  test "returns nil values when not set in Redis" do
          get :show, params: { access_token: access_token.token }

          expect(response).to be_successful
          body = response.parsed_body
          expect(body["minimum_version"]).to be_nil
          expect(body["minimum_update_created_at"]).to be_nil
        end
      end

  context_ "without access token" do
  test "returns unauthorized" do
          get :show

          expect(response).to have_http_status(:unauthorized)
        end
      end

  context_ "with wrong scope" do
        let(:access_token) { create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "mobile_api") }

  test "returns forbidden" do
          get :show, params: { access_token: access_token.token }

          expect(response).to have_http_status(:forbidden)
        end
      end
    end
  end
end
