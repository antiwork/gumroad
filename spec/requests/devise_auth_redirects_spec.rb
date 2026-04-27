# frozen_string_literal: true

require "spec_helper"

describe "Devise auth path redirects", type: :request do
  describe "GET /users/sign_in" do
    it "redirects to /login" do
      get "/users/sign_in"
      expect(response).to redirect_to("/login")
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
  end
end
