# frozen_string_literal: true

require "spec_helper"

describe "Two-Factor Authentication", js: true, type: :system do
  include FillInUserProfileHelpers

  let(:user) { create(:named_user, skip_enabling_two_factor_authentication: false) }

  def login_to_app
    visit login_path

    submit_login_form
  end

  def submit_login_form
    fill_in "Email", with: user.email
    fill_in "Password", with: user.password
    click_on "Login"

    wait_for_ajax
  end

  it "redirects to two_factor_authentication_path on login" do
    expect do
      login_to_app

      expect(page).to have_content "Two-Factor Authentication"
      expect(page).to have_content "To protect your account, we have sent an Authentication Token to #{user.email}. Please enter it here to continue."
      expect(page.current_url).to eq two_factor_authentication_url(next: dashboard_path, host: Capybara.app_host)
    end.to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token).once.with(user.id)
  end

  describe "Submit authentication token" do
    context "when correct token is entered" do
      it "navigates to login_path_for(user) on successful two factor authentication and remembers 2FA status" do
        recreate_model_index(Purchase)
        login_to_app
        expect(page).to have_content "Two-Factor Authentication"
        expect(page).to have_link "Gumroad", href: UrlService.root_domain_with_protocol

        fill_in "Token", with: user.otp_code
        click_on "Login"

        wait_for_ajax

        expect(page.current_url).to eq dashboard_url(host: Capybara.app_host)

        fill_in_profile

        first("nav[aria-label='Main'] details summary").click
        click_on "Logout"
        login_to_app

        # It doesn't ask for 2FA again
        expect(page).to have_text("Dashboard")
      end
    end

    context "when incorrect token is entered" do
      it "shows an error message" do
        login_to_app
        expect(page).to have_content "Two-Factor Authentication"

        fill_in "Token", with: "abcd"
        click_on "Login"

        wait_for_ajax

        expect(page).to have_content("Invalid token, please try again.")
      end
    end
  end

  describe "Resend authentication token" do
    it "resends the authentication token" do
      expect do
        login_to_app
        expect(page).to have_content "Two-Factor Authentication"

        click_on "Resend Authentication Token"

        wait_for_ajax
      end.to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token).twice.with(user.id)
    end
  end

  describe "Two factor auth verification link" do
    it "navigates to logged in path" do
      login_to_app
      expect(page).to have_content "Two-Factor Authentication"

      # Fill the data before opening a new window to make sure the page is fully loaded before switching to the new page.
      fill_in "Token", with: "invalid"

      new_window = open_new_window
      within_window new_window do
        visit verify_two_factor_authentication_path(token: user.otp_code, user_id: user.encrypted_external_id, format: :html)
        expect(page.current_url).to eq dashboard_url(host: Capybara.app_host)
      end

      # Once 2FA is verified through link, it should redirect to logged in page without checking token
      click_on "Login"
      wait_for_ajax
      expect(page.current_url).to eq dashboard_url(host: Capybara.app_host)
    end

    it "navigates to login page when the user is not logged in before" do
      expect do
        two_factor_verify_link = verify_two_factor_authentication_path(token: user.otp_code, user_id: user.encrypted_external_id, format: :html)
        visit two_factor_verify_link

        expect(page.current_url).to eq login_url(host: Capybara.app_host, next: two_factor_verify_link)

        submit_login_form

        # It directly navigates to logged in page since 2FA is verified through the link between the redirects.
        expect(page).to have_text("Dashboard")
        expect(page.current_url).to eq dashboard_url(host: Capybara.app_host)
      end.not_to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token).with(user.id)
    end

    it "allows to login with a valid 2FA token when an expired login link is clicked" do
      two_factor_verify_link = verify_two_factor_authentication_path(token: "invalid", user_id: user.encrypted_external_id, format: :html)
      visit two_factor_verify_link

      expect(page.current_url).to eq login_url(host: Capybara.app_host, next: two_factor_verify_link)
      submit_login_form
      expect(page).to have_content "Two-Factor Authentication"

      fill_in "Token", with: user.otp_code
      click_on "Login"

      wait_for_ajax

      expect(page.current_url).to eq dashboard_url(host: Capybara.app_host)
    end
  end
end
