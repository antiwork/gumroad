# frozen_string_literal: true

require "test_helper"

class RequestsDeviseAuthRedirectsTest < ActionDispatch::IntegrationTest



  context_ "Devise auth path redirects", type: :request do
    include Devise::Test::IntegrationHelpers

    before do
      allow_any_instance_of(ActionDispatch::Request).to receive(:host).and_return(VALID_REQUEST_HOSTS.first)
    end

  context_ "GET /users/sign_in" do
  test "redirects to /login" do
        get "/users/sign_in"
        expect(response).to redirect_to("/login")
      end

  test "preserves query string when redirecting" do
        get "/users/sign_in?next=/dashboard"
        expect(response).to redirect_to("/login?next=/dashboard")
      end

  test "preserves multiple query parameters" do
        get "/users/sign_in?next=/checkout&email=test%40example.com"
        expect(response).to redirect_to("/login?next=/checkout&email=test%40example.com")
      end

  context_ "when user is already signed in" do
        let(:user) { create(:user) }

        before { sign_in user }

  test "redirects to /login without 'already signed in' flash" do
          get "/users/sign_in"
          expect(response).to redirect_to("/login")
          expect(flash[:alert]).to be_nil
        end
      end
    end

  context_ "GET /users/sign_up" do
  test "redirects to /signup" do
        get "/users/sign_up"
        expect(response).to redirect_to("/signup")
      end

  test "preserves query string when redirecting" do
        get "/users/sign_up?referrer=alice"
        expect(response).to redirect_to("/signup?referrer=alice")
      end

  test "preserves multiple query parameters" do
        get "/users/sign_up?referrer=alice&email=test%40example.com"
        expect(response).to redirect_to("/signup?referrer=alice&email=test%40example.com")
      end
    end
  end
end
