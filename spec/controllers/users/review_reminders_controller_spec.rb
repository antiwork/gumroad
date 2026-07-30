# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe Users::ReviewRemindersController, type: :controller, inertia: true do
  describe "GET subscribe" do
    let(:user) { create(:user, opted_out_of_review_reminders: true) }

    context "when user is logged in" do
      it "renders Inertia page and sets opted_out_of_review_reminders flag successfully" do
        sign_in(user)
        expect do
          get :subscribe
        end.to change { user.reload.opted_out_of_review_reminders? }.from(true).to(false)
        expect(response).to be_successful
        expect(inertia).to render_component("Users/ReviewReminders/Subscribe")
      end
    end

    context "when user is not logged in" do
      it "redirects to login page" do
        get :subscribe
        expect(response).to redirect_to(login_url(next: user_subscribe_review_reminders_path))
      end
    end
  end

  describe "GET unsubscribe" do
    let(:user) { create(:user) }

    context "when user is logged in" do
      it "renders Inertia page and sets opted_out_of_review_reminders flag successfully" do
        sign_in(user)
        expect do
          get :unsubscribe
        end.to change { user.reload.opted_out_of_review_reminders? }.from(false).to(true)
        expect(response).to be_successful
        expect(inertia).to render_component("Users/ReviewReminders/Unsubscribe")
      end
    end

    context "when user is not logged in" do
      it "redirects to login page" do
        get :unsubscribe
        expect(response).to redirect_to(login_url(next: user_unsubscribe_review_reminders_path))
      end
    end
  end

  describe "GET unsubscribe_by_token" do
    let(:user) { create(:user) }
    let(:token) { user.secure_external_id(scope: Users::ReviewRemindersController::TOKEN_SCOPE) }

    it "opts the user out without a session" do
      expect do
        get :unsubscribe_by_token, params: { id: token }
      end.to change { user.reload.opted_out_of_review_reminders? }.from(false).to(true)
      expect(response).to be_successful
      expect(inertia).to render_component("Users/ReviewReminders/Unsubscribe")
    end

    it "passes a tokenized resubscribe url so the follow-up link also works without a session" do
      get :unsubscribe_by_token, params: { id: token }

      subscribe_url = inertia.props[:subscribe_url]
      expect(subscribe_url).to be_present
      expect(subscribe_url).not_to eq(user_subscribe_review_reminders_path)

      resubscribe_token = subscribe_url.split("/").last
      expect(User.find_by_secure_external_id(resubscribe_token, scope: Users::ReviewRemindersController::TOKEN_SCOPE)).to eq(user)
    end

    it "is idempotent for an already opted-out user" do
      user.update!(opted_out_of_review_reminders: true)

      get :unsubscribe_by_token, params: { id: token }

      expect(response).to be_successful
      expect(user.reload.opted_out_of_review_reminders?).to be(true)
    end

    it "redirects to root for a garbage token" do
      expect do
        get :unsubscribe_by_token, params: { id: "not-a-real-token" }
      end.not_to change { user.reload.opted_out_of_review_reminders? }
      expect(response).to redirect_to(root_path)
    end

    it "redirects to root for a token minted under a different scope" do
      other_scope_token = user.secure_external_id(scope: "unsubscribe")

      expect do
        get :unsubscribe_by_token, params: { id: other_scope_token }
      end.not_to change { user.reload.opted_out_of_review_reminders? }
      expect(response).to redirect_to(root_path)
    end

    it "redirects to root for a token belonging to a different model" do
      purchase_token = create(:purchase).secure_external_id(scope: Users::ReviewRemindersController::TOKEN_SCOPE)

      get :unsubscribe_by_token, params: { id: purchase_token }

      expect(response).to redirect_to(root_path)
    end

    it "opts out the token's owner rather than the signed-in user" do
      signed_in_user = create(:user)
      sign_in(signed_in_user)

      get :unsubscribe_by_token, params: { id: token }

      expect(user.reload.opted_out_of_review_reminders?).to be(true)
      expect(signed_in_user.reload.opted_out_of_review_reminders?).to be(false)
    end
  end

  describe "GET subscribe_by_token" do
    let(:user) { create(:user, opted_out_of_review_reminders: true) }
    let(:token) { user.secure_external_id(scope: Users::ReviewRemindersController::TOKEN_SCOPE) }

    it "opts the user back in without a session" do
      expect do
        get :subscribe_by_token, params: { id: token }
      end.to change { user.reload.opted_out_of_review_reminders? }.from(true).to(false)
      expect(response).to be_successful
      expect(inertia).to render_component("Users/ReviewReminders/Subscribe")
    end

    it "redirects to root for a garbage token" do
      expect do
        get :subscribe_by_token, params: { id: "not-a-real-token" }
      end.not_to change { user.reload.opted_out_of_review_reminders? }
      expect(response).to redirect_to(root_path)
    end
  end
end
