# frozen_string_literal: true

require "test_helper"

class UsersReviewRemindersControllerTest < ActionController::TestCase
  self.described_class = Users::ReviewRemindersController
  tests Users::ReviewRemindersController



  context_ Users::ReviewRemindersController, type: :controller, inertia: true do
  context_ "GET subscribe" do
      let(:user) { create(:user, opted_out_of_review_reminders: true) }

  context_ "when user is logged in" do
  test "renders Inertia page and sets opted_out_of_review_reminders flag successfully" do
          sign_in(user)
          expect do
            get :subscribe
          end.to change { user.reload.opted_out_of_review_reminders? }.from(true).to(false)
          expect(response).to be_successful
          expect(inertia).to render_component("Users/ReviewReminders/Subscribe")
        end
      end

  context_ "when user is not logged in" do
  test "redirects to login page" do
          get :subscribe
          expect(response).to redirect_to(login_url(next: user_subscribe_review_reminders_path))
        end
      end
    end

  context_ "GET unsubscribe" do
      let(:user) { create(:user) }

  context_ "when user is logged in" do
  test "renders Inertia page and sets opted_out_of_review_reminders flag successfully" do
          sign_in(user)
          expect do
            get :unsubscribe
          end.to change { user.reload.opted_out_of_review_reminders? }.from(false).to(true)
          expect(response).to be_successful
          expect(inertia).to render_component("Users/ReviewReminders/Unsubscribe")
        end
      end

  context_ "when user is not logged in" do
  test "redirects to login page" do
          get :unsubscribe
          expect(response).to redirect_to(login_url(next: user_unsubscribe_review_reminders_path))
        end
      end
    end
  end
end
