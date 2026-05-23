# frozen_string_literal: true

require "test_helper"

class ApiMobileFeatureFlagsControllerTest < ActionController::TestCase
  self.described_class = Api::Mobile::FeatureFlagsController
  tests Api::Mobile::FeatureFlagsController



  context_ Api::Mobile::FeatureFlagsController do
    let(:user) { create(:user) }
    let(:app) { create(:oauth_application, owner: user) }
    let(:params) do
      {
        mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
        access_token: create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "mobile_api").token
      }
    end

  context_ "GET show" do
      let(:feature) { :test_feature }

  context_ "when enabled for all users" do
        before { Feature.activate(feature) }

  test "returns true" do
          get :show, params: params.merge(id: feature)
          expect(response).to be_successful
          expect(response.parsed_body["enabled_for_user"]).to eq(true)
        end
      end

  context_ "when enabled for the logged in user" do
        before { Feature.activate_user(feature, user) }

  test "returns true" do
          get :show, params: params.merge(id: feature)
          expect(response).to be_successful
          expect(response.parsed_body["enabled_for_user"]).to eq(true)
        end
      end

  context_ "when enabled for a different user" do
        before { Feature.activate_user(feature, create(:user)) }

  test "returns false" do
          get :show, params: params.merge(id: feature)
          expect(response).to be_successful
          expect(response.parsed_body["enabled_for_user"]).to eq(false)
        end
      end

  context_ "when not enabled" do
  test "returns false" do
          get :show, params: params.merge(id: feature)
          expect(response).to be_successful
          expect(response.parsed_body["enabled_for_user"]).to eq(false)
        end
      end
    end
  end
end
