# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe Oauth::AuthorizedApplicationsController do
  before do
    @user = create(:user)
    @application = create(:oauth_application, owner: @user)
    create("doorkeeper/access_token", resource_owner_id: @user.id, application: @application, scopes: "creator_api")
    sign_in @user
  end

  describe "GET index" do
    it "redirects to settings_authorized_applications_path" do
      get :index
      expect(response).to redirect_to settings_authorized_applications_path
    end
  end

  describe "DELETE destroy" do
    it "revokes access to the authorized application and redirects" do
      expect { delete(:destroy, params: { id: @application.external_id }) }.to change { OauthApplication.authorized_for(@user).count }.by(-1)
      expect(response).to redirect_to(settings_authorized_applications_path)
      expect(flash[:notice]).to eq("Authorized application revoked")
    end

    context "when the user hasn't authorized the application" do
      it "redirects with error message" do
        delete :destroy, params: { id: "invalid_id" }
        expect(response).to redirect_to(settings_authorized_applications_path)
        expect(flash[:alert]).to eq("Authorized application could not be revoked")
      end
    end
  end
end
