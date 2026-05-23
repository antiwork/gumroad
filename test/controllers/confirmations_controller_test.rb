# frozen_string_literal: true

require "test_helper"

class ConfirmationsControllerTest < ActionController::TestCase
  self.described_class = ConfirmationsController
  tests ConfirmationsController



  context_ ConfirmationsController do
    before do
      request.env["devise.mapping"] = Devise.mappings[:user]
      @user = create(:user, confirmed_at: nil)
    end

  context_ "#show" do
  context_ "already confirmed" do
        before do
          @confirmation_token = @user.confirmation_token
          @user.confirm
        end

  test "redirects home" do
          get :show, params: { confirmation_token: @confirmation_token }
          expect(response).to redirect_to root_url
        end
      end

  context_ "logged in" do
        before do
          sign_in @user
        end

  test "confirms the user" do
          expect do
            get :show, params: { confirmation_token: @user.confirmation_token }
          end.to change {
            @user.reload.confirmed?
          }.from(false).to(true)
        end
      end

  context_ "logged out" do
  test "redirects user to settings page after confirmation" do
          get :show, params: { confirmation_token: @user.confirmation_token }
          expect(response).to redirect_to dashboard_url
        end

  test "confirms the user" do
          expect do
            get :show, params: { confirmation_token: @user.confirmation_token }
          end.to change {
            @user.reload.confirmed?
          }.from(false).to(true)
        end

  test "logs in the user" do
          expect do
            get :show, params: { confirmation_token: @user.confirmation_token }
          end.to change {
                   subject.logged_in_user.nil?
                 }.from(true).to(false)
        end

  test "invalidates the user's active sessions and keeps the current session active" do
          old_email = @user.email
          @user.update!(unconfirmed_email: "new@example.com")

          freeze_time do
            expect do
              get :show, params: { confirmation_token: @user.confirmation_token }
            end.to change { @user.reload.email }.from(old_email).to("new@example.com")
             .and change { @user.unconfirmed_email }.from("new@example.com").to(nil)
             .and change { @user.last_active_sessions_invalidated_at }.from(nil).to(DateTime.current)

            expect(request.env["warden"].session["last_sign_in_at"]).to eq(DateTime.current.to_i)
          end
        end

  context_ "when the user has requested password reset instructions" do
          before do
            @user.send_reset_password_instructions
          end

  test "invalidates the user's reset password token" do
            expect(@user.reset_password_token).to be_present

            expect do
              get :show, params: { confirmation_token: @user.confirmation_token }
            end.to change { @user.reload.reset_password_token }.to(nil)
            .and change { @user.reset_password_sent_at }.to(nil)
          end
        end

  context_ "when user is already confirmed" do
          before do
            @user.confirm
          end

  test "does not invalidate the user's active sessions" do
            expect do
              get :show, params: { confirmation_token: @user.confirmation_token }
            end.not_to change { @user.reload.last_active_sessions_invalidated_at }
          end
        end
      end
    end
  end
end
