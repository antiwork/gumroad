# frozen_string_literal: true

require "spec_helper"

describe "Devise auth path redirects", type: :request do
  include Devise::Test::IntegrationHelpers

  before do
    allow_any_instance_of(ActionDispatch::Request).to receive(:host).and_return(VALID_REQUEST_HOSTS.first)
  end

  describe "GET /users/sign_in" do
    it "redirects to /login" do
      get "/users/sign_in"
      expect(response).to redirect_to("/login")
    end

    it "preserves query string when redirecting" do
      get "/users/sign_in?next=/dashboard"
      expect(response).to redirect_to("/login?next=/dashboard")
    end

    it "preserves multiple query parameters" do
      get "/users/sign_in?next=/checkout&email=test%40example.com"
      expect(response).to redirect_to("/login?next=/checkout&email=test%40example.com")
    end

    context "when user is already signed in" do
      let(:user) { create(:user) }

      before { sign_in user }

      it "redirects to /login without 'already signed in' flash" do
        get "/users/sign_in"
        expect(response).to redirect_to("/login")
        expect(flash[:alert]).to be_nil
      end
    end
  end

  describe "GET /users/sign_up" do
    it "redirects to /signup" do
      get "/users/sign_up"
      expect(response).to redirect_to("/signup")
    end

    it "preserves query string when redirecting" do
      get "/users/sign_up?referrer=alice"
      expect(response).to redirect_to("/signup?referrer=alice")
    end

    it "preserves multiple query parameters" do
      get "/users/sign_up?referrer=alice&email=test%40example.com"
      expect(response).to redirect_to("/signup?referrer=alice&email=test%40example.com")
    end
  end

  describe "/login when already signed in" do
    let(:user) { create(:user) }
    let(:expected_redirect) { dashboard_url(host: VALID_REQUEST_HOSTS.first) }

    before { sign_in user }

    it "redirects GET to the dashboard without 'already signed in' flash" do
      get "/login"
      expect(response).to redirect_to(expected_redirect)
      expect(flash[:alert]).to be_nil
    end

    it "redirects HTML POST to the dashboard without 'already signed in' flash" do
      post "/login", params: { user: { login_identifier: user.email, password: "irrelevant" } }
      expect(response).to redirect_to(expected_redirect)
      expect(flash[:alert]).to be_nil
    end
  end

  describe "/signup when already signed in" do
    let(:user) { create(:user) }
    let(:expected_redirect) { dashboard_url(host: VALID_REQUEST_HOSTS.first) }

    before { sign_in user }

    it "redirects GET to the dashboard without 'already signed in' flash" do
      get "/signup"
      expect(response).to redirect_to(expected_redirect)
      expect(flash[:alert]).to be_nil
    end

    it "redirects HTML POST to the dashboard without 'already signed in' flash and without creating a new user" do
      expect do
        post "/signup", params: { user: { email: "fresh-#{SecureRandom.hex(4)}@example.com", password: "Password123!" } }
      end.not_to change(User, :count)

      expect(response).to redirect_to(expected_redirect)
      expect(flash[:alert]).to be_nil
    end
  end
end
