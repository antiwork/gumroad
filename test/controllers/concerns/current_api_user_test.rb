# frozen_string_literal: true

require "test_helper"

class CurrentApiUserTest < ActionController::TestCase
  self.described_class = CurrentApiUser



  context_ CurrentApiUser, type: :controller do
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

  context_ "#current_api_user" do
  context_ "without a doorkeeper token" do
  test "returns nil" do
          get :action
          expect(controller.current_api_user).to be(nil)
        end
      end

  context_ "with a valid doorkeeper token" do
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

  test "returns the user associated with the token" do
          get(:action, params:)
          expect(controller.current_api_user).to eq(user)
        end
      end

  context_ "with an invalid doorkeeper token" do
        let(:access_token) { "invalid" }

        before do
          @request.params["access_token"] = access_token
        end

  test "returns nil" do
          get :action
          expect(controller.current_api_user).to be(nil)
        end
      end

  test "does not error with invalid POST data" do
        post :action, body: '{ "abc"#012: "xyz" }', as: :json
        expect(controller.current_api_user).to eq(nil)
      end
    end
  end
end
