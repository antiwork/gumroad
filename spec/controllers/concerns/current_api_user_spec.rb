# frozen_string_literal: true

require "spec_helper"

describe CurrentApiUser, type: :controller do
  controller(ApplicationController) do
    include CurrentApiUser

    skip_before_action :set_signup_referrer

    def action
      head :ok
    end
  end

  before do
    routes.draw { match :action, to: "anonymous#action", via: [:get, :post] }
  end

  describe "#current_api_user" do
    context "without a doorkeeper token" do
      it "returns nil" do
        get :action
        expect(controller.current_api_user).to be(nil)
      end
    end

    context "with a valid doorkeeper token" do
      let(:user) { create(:user) }
      let(:application) { create(:oauth_application) }
      let(:access_token) do
        create(
          "doorkeeper/access_token",
          application:,
          resource_owner_id: user.id,
          scopes: "creator_api"
        ).token
      end
      let(:params) do
        {
          mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
          access_token:
        }
      end

      it "returns the user associated with the token" do
        get(:action, params:)
        expect(controller.current_api_user).to eq(user)
      end
    end

    context "with an invalid doorkeeper token" do
      let(:access_token) { "invalid" }

      before do
        @request.params["access_token"] = access_token
      end

      it "returns nil" do
        get :action
        expect(controller.current_api_user).to be(nil)
      end
    end

    it "does not error with invalid POST data" do
      post :action, body: '{ "abc"#012: "xyz" }', as: :json
      expect(controller.current_api_user).to eq(nil)
    end
  end
end
