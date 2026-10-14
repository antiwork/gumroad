# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe "Google sign-in to an unconfirmed account created with a password", type: :request, inertia: true do
  include Devise::Test::IntegrationHelpers

  let(:google_auth) do
    OmniAuth::AuthHash.new(JSON.parse(File.read(Rails.root.join("spec/support/fixtures/google_omniauth.json")))).tap { _1.info.image = nil }
  end
  let!(:squatter_account) { create(:unconfirmed_user, email: google_auth.info.email, password: "squatter-password-4821") }

  around do |example|
    previous_test_mode = OmniAuth.config.test_mode
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = google_auth
    example.run
  ensure
    OmniAuth.config.test_mode = previous_test_mode
    OmniAuth.config.mock_auth.delete(:google_oauth2)
  end

  def new_browser
    open_session.tap { _1.host! DOMAIN }
  end

  def settings_status(browser)
    browser.get settings_main_path, headers: { "X-Inertia" => "true" }
    browser.response.status
  end

  def drop_session_cookie(browser)
    browser.cookies.delete(Rails.application.config.session_options[:key])
  end

  it "signs the Google user in and ends the squatter's session and remember-me cookie", :aggregate_failures do
    squatter = new_browser
    remembered = new_browser
    travel_to(1.minute.ago) do
      sign_in squatter_account
      expect(settings_status(squatter)).to eq(200)

      squatter_account.update!(remember_created_at: 1.minute.ago)
      squatter_account.remember_me = true
      sign_in squatter_account
      expect(settings_status(remembered)).to eq(200)
    end
    travel_to(30.seconds.ago) do
      drop_session_cookie(remembered)
      expect(settings_status(remembered)).to eq(200)
      drop_session_cookie(remembered)
    end

    google = new_browser
    google.get user_google_oauth2_omniauth_callback_path

    expect(google.response.location).to eq(dashboard_url(host: DOMAIN))
    expect(squatter_account.reload).to be_confirmed
    expect(squatter_account.valid_password?("squatter-password-4821")).to be(false)
    expect(settings_status(remembered)).to eq(302)
    expect(remembered.response.location).to start_with(login_url(host: DOMAIN))
    expect(settings_status(squatter)).to eq(302)
    expect(squatter.response.location).to start_with(login_url(host: DOMAIN))
    expect(settings_status(google)).to eq(200)
  end
end
