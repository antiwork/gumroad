# frozen_string_literal: true

require "spec_helper"

describe "Login Feature Scenario", js: true, type: :system do
  let(:user) { create(:user) }

  before do
    ignore_js_error(/Error retrieving login status, fetch cancelled./)
  end

  describe "login", type: :system do
    it "logs in a user" do
      visit login_path
      expect(page).to_not have_alert
      expect(page).to have_link "Gumroad", href: UrlService.root_domain_with_protocol

      fill_in "Email", with: user.email
      fill_in "Password", with: user.password

      click_on "Login"
      expect(page).to have_selector("iframe[title*=recaptcha]", visible: false)
      wait_for_ajax
      expect(page).to have_content("Dashboard")
    end

    it "shows an error when login fails" do
      visit login_path
      expect(page).to_not have_alert

      fill_in "Email", with: user.email
      fill_in "Password", with: "someotherpassword"

      click_on "Login"
      wait_for_ajax
      expect(page).to have_alert(text: "Please try another password. The one you entered was incorrect.")
      expect(page).to have_button("Login")
    end
  end

  describe "OAuth login", type: :system do
    before do
      @oauth_application = create(:oauth_application)
      @oauth_authorize_url = oauth_authorization_path(client_id: @oauth_application.uid, redirect_uri: @oauth_application.redirect_uri, scope: "edit_products")
      visit @oauth_authorize_url
    end

    it "sets the application name and 'next' query string in sign up link" do
      expect(page.has_content?("Connect #{@oauth_application.name} to Gumroad")).to be(true)
      expect(page).to have_link("Sign up", href: signup_path(next: @oauth_authorize_url))
    end

    it "navigates to OAuth authorization page" do
      fill_in "Email", with: user.email
      fill_in "Password", with: user.password
      click_on "Login"
      wait_for_ajax

      expect(page.has_content?("Authorize #{@oauth_application.name} to use your account?")).to be(true)
    end
  end

  describe "Social login" do
    let(:user) { create(:user) }

    before do
      OmniAuth.config.test_mode = true
    end

    it "supports logging in with Facebook" do
      OmniAuth.config.mock_auth[:facebook] = OmniAuth::AuthHash.new(JSON.parse(File.read("#{Rails.root}/spec/support/fixtures/facebook_omniauth.json")))
      user.update!(facebook_uid: OmniAuth.config.mock_auth[:facebook][:uid])

      visit signup_path

      expect do
        click_button "Facebook"
        expect(page).to have_content("We're here to help you get paid for your work.")
      end.not_to change(User, :count)
    end

    it "supports logging in with Google" do
      OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(JSON.parse(File.read("#{Rails.root}/spec/support/fixtures/google_omniauth.json")))
      user.update!(google_uid: OmniAuth.config.mock_auth[:google_oauth2][:uid])

      visit signup_path

      expect do
        click_button "Google"
        expect(page).to have_content("We're here to help you get paid for your work.")
      end.not_to change(User, :count)
    end

    it "supports logging in with X" do
      OmniAuth.config.mock_auth[:twitter] = OmniAuth::AuthHash.new(JSON.parse(File.read("#{Rails.root}/spec/support/fixtures/twitter_omniauth.json")))
      user.update!(twitter_user_id: OmniAuth.config.mock_auth[:twitter][:extra][:raw_info][:id])

      visit signup_path

      expect do
        click_button "X"
        expect(page).to have_content("We're here to help you get paid for your work.")
      end.not_to change(User, :count)
    end

    it "supports logging in with Stripe" do
      OmniAuth.config.mock_auth[:stripe_connect] = OmniAuth::AuthHash.new(JSON.parse(File.read("#{Rails.root}/spec/support/fixtures/stripe_connect_omniauth.json")))
      create(:merchant_account_stripe_connect, user:, charge_processor_merchant_id: OmniAuth.config.mock_auth[:stripe_connect][:uid])

      visit signup_path

      expect do
        click_button "Stripe"
        expect(page).to have_content("We're here to help you get paid for your work.")
      end.not_to change(User, :count)
    end
  end

  describe "Prefill team invitation email" do
    let(:team_invitation) { create(:team_invitation) }

    it "prefills the email" do
      visit login_path(next: accept_settings_team_invitation_path(team_invitation.external_id, email: team_invitation.email))

      expect(find_field("Email").value).to eq(team_invitation.email)
    end
  end

  describe "reset password" do
    it "sends a reset password email" do
      visit login_path

      click_on "Forgot your password?"
      fill_in "Email to send reset instructions to", with: user.email
      click_on "Send"
      wait_for_ajax

      expect(page).to have_alert(text: "Password reset sent! Please make sure to check your spam folder.")
      expect(user.reload.reset_password_sent_at).to be_present
    end

    it "shows an error for a nonexistent account" do
      visit login_path

      click_on "Forgot your password?"
      fill_in "Email to send reset instructions to", with: "notauser@example.com"
      click_on "Send"
      wait_for_ajax

      expect(page).to have_alert(text: "An account does not exist with that email.")
    end
  end
end
