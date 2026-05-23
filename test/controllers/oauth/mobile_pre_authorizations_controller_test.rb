# frozen_string_literal: true

require "test_helper"

class OauthMobilePreAuthorizationsControllerTest < ActionController::TestCase
  self.described_class = Oauth::MobilePreAuthorizationsController
  tests Oauth::MobilePreAuthorizationsController



  context_ Oauth::MobilePreAuthorizationsController do
    render_views

  context_ "GET new" do
  context_ "when user is logged in" do
        before do
          @user = create(:user)
          sign_in @user
        end

  test "renders the pre-authorization prompt with user details and sets the mobile app cookie" do
          request.env["HTTPS"] = "on"
          get :new, params: { client_id: "abc", redirect_uri: "gumroadmobile://", response_type: "code" }

          expect(response).to have_http_status(:ok)
          expect(response.body).to include(@user.display_name)
          expect(response.body).to include(@user.email)
          expect(response.body).to include("/oauth/authorize?client_id=abc&amp;redirect_uri=gumroadmobile%3A%2F%2F&amp;response_type=code")
          expect(response.body).to include("Continue")
          expect(response.body).to include("Use a different account")
          expect(response.headers["Set-Cookie"]).to include(a_string_including("gumroad_mobile_app=1"))
        end
      end

  context_ "when user is not logged in" do
  test "redirects to the oauth authorize url with query params and sets the mobile app cookie" do
          request.env["HTTPS"] = "on"
          get :new, params: { client_id: "abc", redirect_uri: "gumroadmobile://", response_type: "code" }

          expect(response).to redirect_to("/oauth/authorize?client_id=abc&redirect_uri=gumroadmobile%3A%2F%2F&response_type=code")
          expect(response.headers["Set-Cookie"]).to include(a_string_including("gumroad_mobile_app=1"))
        end
      end
    end

  context_ "GET switch_account" do
  context_ "when user is signed in" do
        before do
          @user = create(:user)
          sign_in @user
        end

  test "signs out the user and redirects to oauth authorize with query params" do
          get :switch_account, params: { client_id: "abc", redirect_uri: "gumroadmobile://", response_type: "code" }

          expect(controller.user_signed_in?).to eq(false)
          expect(response).to redirect_to("/oauth/authorize?client_id=abc&redirect_uri=gumroadmobile%3A%2F%2F&response_type=code")
        end
      end

  context_ "when user is not signed in" do
  test "redirects to oauth authorize with query params" do
          get :switch_account, params: { client_id: "abc", redirect_uri: "gumroadmobile://", response_type: "code" }

          expect(response).to redirect_to("/oauth/authorize?client_id=abc&redirect_uri=gumroadmobile%3A%2F%2F&response_type=code")
        end
      end
    end
  end
end
