# frozen_string_literal: true

require "spec_helper"

# These exercise Gumroad's browser/OAuth navigation boundary, not vendor consent.
describe "Onboarding social connection return", js: true, type: :system do
  let(:seller) { create(:named_seller) }

  before do
    @previous_test_mode = OmniAuth.config.test_mode
    OmniAuth.config.test_mode = true
    login_as seller
  end

  after do
    OmniAuth.config.test_mode = @previous_test_mode
    OmniAuth.config.mock_auth.delete(:twitter)
    OmniAuth.config.mock_auth.delete(:youtube)
    OmniAuth.config.mock_auth.delete(:instagram)
  end

  it "clears the continuation when the seller leaves without connecting" do
    visit dashboard_path
    click_on "Manage social connections"
    expect(page).to have_current_path(settings_social_connections_path(social_connect_origin: "onboarding"))
    expect(page).to have_button("Connect to X")
    expect(page).to have_css("form[action*='social_connect_return=']", visible: :all)
    visit dashboard_path
    expect(page).to have_text("X: Available to connect")
    visit settings_social_connections_path
    expect(page).not_to have_css("form[action*='social_connect_return=']", visible: :all)
  end

  %w[twitter youtube instagram].each do |provider|
    it "returns from #{provider} cancellation to Getting started" do
      Feature.activate_user(:"#{provider}_connect", seller) unless provider == "twitter"
      OmniAuth.config.mock_auth[provider.to_sym] = :access_denied
      visit dashboard_path
      click_on "Manage social connections"
      click_on "Connect to #{ { 'twitter' => 'X', 'youtube' => 'YouTube', 'instagram' => 'Instagram' }.fetch(provider)}"
      expect(page).to have_current_path(dashboard_path)
      expect(page).to have_text("Couldn't connect")
      expect(page).to have_link("Manage social connections")
      expect(seller.reload.twitter_user_id).to be_nil
      expect(seller.youtube_identity).to be_nil
      expect(seller.instagram_identity).to be_nil
    end
  end

  %w[youtube instagram].each do |provider|
    it "returns to onboarding when #{provider} becomes unavailable before authorization" do
      OmniAuth.config.test_mode = false
      Feature.activate_user(:"#{provider}_connect", seller)
      visit dashboard_path
      click_on "Manage social connections"
      Feature.deactivate_user(:"#{provider}_connect", seller)
      click_on "Connect to #{provider == 'youtube' ? 'YouTube' : 'Instagram'}"
      expect(page).to have_current_path(dashboard_path)
      expect(page).to have_text("Couldn't connect")
      expect(seller.reload.youtube_identity).to be_nil
      expect(seller.instagram_identity).to be_nil
      visit settings_social_connections_path
      expect(page).not_to have_css("form[action*='social_connect_return=']", visible: :all)
    end
  end

  it "returns from successful X linking and displays the current connection" do
    auth = JSON.parse(File.read(Rails.root.join("spec/support/fixtures/twitter_omniauth.json")))
    OmniAuth.config.mock_auth[:twitter] = OmniAuth::AuthHash.new(auth)
    visit dashboard_path
    click_on "Manage social connections"
    click_on "Connect to X"
    expect(page).to have_current_path(dashboard_path)
    expect(page).to have_text("X: Connected")
    expect(seller.reload.twitter_user_id).to be_present
  end
end
