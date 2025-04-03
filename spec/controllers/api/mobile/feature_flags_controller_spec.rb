# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::FeatureFlagsController do
  let(:user) { create(:user) }
  let(:app) { create(:oauth_application, owner: user) }
  let(:params) do
    {
      mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
      access_token: create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "mobile_api").token
    }
  end

  describe "GET show" do
    let(:feature) { :test_feature }

    context "when enabled for all users" do
      before { Feature.activate(feature) }

      it "returns true" do
        get :show, params: params.merge(id: feature)
        expect(response).to be_successful
        expect(response.parsed_body["enabled_for_user"]).to eq(true)
      end
    end

    context "when enabled for the logged in user" do
      before { Feature.activate_user(feature, user) }

      it "returns true" do
        get :show, params: params.merge(id: feature)
        expect(response).to be_successful
        expect(response.parsed_body["enabled_for_user"]).to eq(true)
      end
    end

    context "when enabled for a different user" do
      before { Feature.activate_user(feature, create(:user)) }

      it "returns false" do
        get :show, params: params.merge(id: feature)
        expect(response).to be_successful
        expect(response.parsed_body["enabled_for_user"]).to eq(false)
      end
    end

    context "when not enabled" do
      it "returns false" do
        get :show, params: params.merge(id: feature)
        expect(response).to be_successful
        expect(response.parsed_body["enabled_for_user"]).to eq(false)
      end
    end
  end
end
