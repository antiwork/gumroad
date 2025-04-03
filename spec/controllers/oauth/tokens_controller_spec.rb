# frozen_string_literal: true

require "spec_helper"

describe Oauth::TokensController do
  let(:password) { Devise.friendly_token[0, 20] }
  let(:user) { create(:user, password:, password_confirmation: password) }
  let(:application) { create(:oauth_application) }

  context "when the user is active" do
    it "returns a token response" do
      post :create, params: {
        grant_type: "password",
        client_id: application.uid,
        client_secret: application.secret,
        username: user.email,
        password:
      }

      expect(response).to be_successful
      expect(response.parsed_body["access_token"]).to be_present
    end
  end

  context "when the user is deactivated" do
    before do
      user.deactivate!
    end

    it "returns HTTP Bad Request" do
      post :create, params: {
        grant_type: "password",
        client_id: application.uid,
        client_secret: application.secret,
        username: user.email,
        password:
      }

      expect(response).to be_bad_request
    end
  end
end
