# frozen_string_literal: true

require "spec_helper"

describe "Signup Feature Scenario", js: true, type: :system do
  let(:user) { create(:user) }

  it "supports signing up with password" do
    visit signup_path
    expect(page).to_not have_alert
    expect(page).to have_link "Gumroad", href: UrlService.root_domain_with_protocol

    fill_in "Email", with: Faker::Internet.email
    fill_in "Password", with: SecureRandom.hex(16)

    expect do
      click_on "Create account"
      expect(page).to have_selector("iframe[title*=recaptcha]", visible: false)
      wait_for_ajax
      expect(page).to have_content("Welcome to Gumroad.")
    end.to change(User, :count).by(1)
  end

  it "supports signing in via the signup form" do
    visit signup_path
    expect(page).to_not have_alert

    fill_in "Email", with: user.email
    fill_in "Password", with: user.password

    expect do
      click_on "Create account"
      wait_for_ajax
      expect(page).to have_content("Welcome to Gumroad.")
    end.not_to change(User, :count)
  end

  it "shows an error when signup fails" do
    visit signup_path
    expect(page).to_not have_alert

    fill_in "Email", with: user.email
    fill_in "Password", with: "someotherpassword"
    click_on "Create account"

    wait_for_ajax
    expect(page).to have_alert("An account already exists with this email.")
    expect(page).to have_button("Create account")
  end

  it "supports signing up via referral" do
    referrer = create(:user, name: "I am a referrer")
    visit signup_path(referrer: referrer.username)
    expect(page).to have_content("Join I am a referrer on Gumroad")

    fill_in "Email", with: Faker::Internet.email
    fill_in "Password", with: SecureRandom.hex(16)

    expect do
      click_on "Create account"
      wait_for_ajax
      expect(page).to have_content("Welcome to Gumroad.")
    end.to change(User, :count).by(1)

    expect(Invite.last).to have_attributes(sender_id: referrer.id, receiver_email: User.last.email, invite_state: "signed_up")
  end

  describe "Sign up and connect OAuth app" do
    before do
      @oauth_application = create(:oauth_application)
      @oauth_authorize_url = oauth_authorization_path(client_id: @oauth_application.uid, redirect_uri: @oauth_application.redirect_uri, scope: "edit_products")
      visit signup_path(next: @oauth_authorize_url)
    end

    it "sets the application name and 'next' query string in login link" do
      expect(page).to have_content("Sign up for Gumroad and connect #{@oauth_application.name}")
      expect(page).to have_link("Log in", href: login_path(next: @oauth_authorize_url))
    end

    it "navigates to OAuth authorization page" do
      fill_in "Email", with: user.email
      fill_in "Password", with: user.password
      click_on "Create account"

      wait_for_ajax

      expect(page).to have_content("Authorize #{@oauth_application.name} to use your account?")
    end
  end

  describe "Social signup" do
    before do
      OmniAuth.config.test_mode = true
    end

    it "supports signing up with Facebook" do
      OmniAuth.config.mock_auth[:facebook] = OmniAuth::AuthHash.new(JSON.parse(File.read("#{Rails.root}/spec/support/fixtures/facebook_omniauth.json")))

      visit signup_path

      expect do
        click_button "Facebook"
        click_button "Login" # 2FA
        expect(page).to have_content("We're here to help you get paid for your work.")
      end.to change(User, :count).by(1)
    end

    it "supports signing up with Google" do
      OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(JSON.parse(File.read("#{Rails.root}/spec/support/fixtures/google_omniauth.json")))

      visit signup_path

      expect do
        click_button "Google"
        click_button "Login" # 2FA
        expect(page).to have_content("We're here to help you get paid for your work.")
      end.to change(User, :count).by(1)
    end

    it "supports signing up with X" do
      OmniAuth.config.mock_auth[:twitter] = OmniAuth::AuthHash.new(JSON.parse(File.read("#{Rails.root}/spec/support/fixtures/twitter_omniauth.json")))

      visit signup_path

      expect do
        click_button "X"
        expect(page).to have_alert(text: "Please enter an email address!")
      end.to change(User, :count).by(1)
    end

    it "supports signing up with Stripe" do
      OmniAuth.config.mock_auth[:stripe_connect] = OmniAuth::AuthHash.new(JSON.parse(File.read("#{Rails.root}/spec/support/fixtures/stripe_connect_omniauth.json")))

      visit signup_path

      expect do
        click_button "Stripe"
        expect(page).to have_content("We're here to help you get paid for your work.")
      end.to change(User, :count).by(1)
    end
  end

  describe "Prefill team invitation email" do
    let(:team_invitation) { create(:team_invitation) }

    it "prefills the email" do
      visit signup_path(next: accept_settings_team_invitation_path(team_invitation.external_id, email: team_invitation.email))

      expect(page).to have_field("Email", with: team_invitation.email)
    end
  end
end
