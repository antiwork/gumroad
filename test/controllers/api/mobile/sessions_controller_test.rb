# frozen_string_literal: true

require "test_helper"

class ApiMobileSessionsControllerTest < ActionController::TestCase
  self.described_class = Api::Mobile::SessionsController
  self.rspec_metadata = { vcr: true }
  tests Api::Mobile::SessionsController



  context_ Api::Mobile::SessionsController, :vcr do
    before do
      @user = create(:user)
      @app = create(:oauth_application, owner: @user)
      @params = {
        mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
        access_token: create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "mobile_api").token
      }
    end

  context_ "POST create" do
  context_ "with valid credentials" do
  test "signs in the user and responds with HTTP success" do
          post :create, params: @params

          expect(controller.current_user).to eq(@user)
          expect(response).to be_successful
          expect(response.parsed_body["success"]).to eq(true)
          expect(response.parsed_body["user"]["email"]).to eq @user.email
        end
      end

  context_ "with invalid credentials" do
  test "responds with HTTP unauthorized" do
          post :create, params: @params.merge(access_token: "invalid")

          expect(response).to have_http_status(:unauthorized)
        end
      end
    end
  end
end
