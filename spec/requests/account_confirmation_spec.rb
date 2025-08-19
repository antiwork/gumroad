# frozen_string_literal: true

require "spec_helper"

describe "Account Confirmation", js: true, type: :system do
  let(:user) { create(:user) }

  it "confirms the unconfirmed email and signs out from all other active sessions" do
    session_1 = :session_1
    session_2 = :session_2

    Capybara.using_session(session_1) do
      travel_to(1.hour.ago) { login_as(user) }

      visit(settings_main_path)
    end

    # Change email from :session_1
    Capybara.using_session(session_1) do
      within(find("header", text: "User details").ancestor("section")) do
        fill_in("Email", with: "new@example.com")
      end

      expect do
        click_on("Update settings")
        wait_for_ajax
      end.to_not change { user.reload.last_active_sessions_invalidated_at }

      refresh

      expect(page).to have_current_path(settings_main_path)
    end

    # Access the email confirmation link received in inbox from :session_1
    Capybara.using_session(session_1) do
      old_email = user.email

      freeze_time do
        expect do
          visit(user_confirmation_path(confirmation_token: user.confirmation_token))
        end.to change { user.reload.email }.from(old_email).to("new@example.com")
         .and change { user.unconfirmed_email }.from("new@example.com").to(nil)
         .and change { user.reload.last_active_sessions_invalidated_at }.from(nil).to(DateTime.current)
      end

      expect(page).to have_current_path(dashboard_path)

      # Ensure this session remains active
      visit(settings_main_path)
      expect(page).to have_current_path(settings_main_path)
    end

    # Verify that session_2 is no longer active
    Capybara.using_session(session_2) do
      visit(settings_main_path)
      expect(page).to have_current_path(login_path + "?next=" + CGI.escape(settings_main_path))
    end
  end

  context "when user has already requested password reset instructions" do
    before do
      # User requests reset password instructions
      @raw_token = user.send_reset_password_instructions
    end

    it "confirms the unconfirmed email and invalidates the requested reset password token" do
      user_session = :user_session
      attacker_session = :attacker_session

      # User remembers their credentials and logs in with it
      Capybara.using_session(user_session) do
        login_as(user)

        # User realizes that their email is compromised, hence changes it
        visit(settings_main_path)
        within(find("header", text: "User details").ancestor("section")) do
          fill_in("Email", with: "new@example.com")
        end

        click_on("Update settings")
        wait_for_ajax
        expect(page).to(have_alert(text: "Your account has been updated!"))

        # User confirms the changed email by accessing the confirmation link
        # received on their changed email address.
        # Doing so also invalidates the already received reset password link
        # on the old compromised email.
        compromised_email = user.email

        expect do
          visit(user_confirmation_path(confirmation_token: user.confirmation_token))
        end.to change { user.reload.email }.from(compromised_email).to("new@example.com")
         .and change { user.reset_password_token }.to(nil)
         .and change { user.reset_password_sent_at }.to(nil)
         .and change { User.with_reset_password_token(@raw_token) }.from(an_instance_of(User)).to(nil)

        expect(page).to(have_alert(text: "Your account has been successfully confirmed!"))
        expect(page).to have_current_path(dashboard_path)
      end

      # Attacker gains access to user's old email inbox and finds an active
      # reset password link mail; uses it to try resetting the user's password!
      Capybara.using_session(attacker_session) do
        reset_password_link = edit_user_password_path(reset_password_token: @raw_token)
        visit(reset_password_link)

        # Attacker finds that the reset password link doesn't work!
        expect(page).to(have_alert(text: "That reset password token doesn't look valid (or may have expired)."))
        expect(page).to have_current_path(login_path)
      end
    end
  end
end
