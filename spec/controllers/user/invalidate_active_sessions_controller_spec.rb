# frozen_string_literal: true

require "spec_helper"

describe User::InvalidateActiveSessionsController do
  describe "PUT update" do
    let(:user) { create(:user) }
    let(:oauth_application) { create(:oauth_application, uid: OauthApplication::MOBILE_API_OAUTH_APPLICATION_UID) }
    let!(:active_access_token_one) { create("doorkeeper/access_token", application: oauth_application, resource_owner_id: user.id, scopes: "mobile_api") }
    let!(:active_access_token_two) { create("doorkeeper/access_token", application: oauth_application, resource_owner_id: user.id, scopes: "mobile_api") }
    let!(:active_access_token_of_another_user) { create("doorkeeper/access_token", application: oauth_application, scopes: "mobile_api") }

    context "when user is not signed in" do
      it "redirects to the login page" do
        put :update

        expect(response).to_not be_successful
        expect(response).to redirect_to(login_path(next: user_invalidate_active_sessions_path))
      end
    end

    context "when user is signed in" do
      before(:each) do
        sign_in user
      end

      it "updates user's 'last_active_sessions_invalidated_at' field and signs out the user" do
        travel_to(DateTime.current) do
          expect do
            put :update
          end.to change { user.reload.last_active_sessions_invalidated_at }.from(nil).to(DateTime.current)
           .and change { controller.logged_in_user }.from(user).to(nil)
           .and change { active_access_token_one.reload.revoked_at }.from(nil).to(DateTime.current)
           .and change { active_access_token_two.reload.revoked_at }.from(nil).to(DateTime.current)

          expect(active_access_token_of_another_user.reload.revoked_at).to be_nil
        end

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)
        expect(flash[:notice]).to eq("You have been signed out from all your active sessions. Please login again.")
      end
    end
  end
end
