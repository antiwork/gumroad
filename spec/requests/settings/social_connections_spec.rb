# frozen_string_literal: true

require "spec_helper"

describe "Settings social connections page", type: :system, js: true do
  let(:seller) { create(:named_seller) }

  before do
    @previous_test_mode = OmniAuth.config.test_mode
    OmniAuth.config.test_mode = true
    login_as seller
  end

  after do
    OmniAuth.config.test_mode = @previous_test_mode
    OmniAuth.config.mock_auth.delete(:twitter)
  end

  it "renders connect controls for the owner and keeps Connect ahead of Continue" do
    visit settings_social_connections_path(social_connect_origin: "onboarding")

    expect(page).to have_text("Social connections")
    expect(page).to have_text("Connecting is optional and helps verify your account")
    expect(page).to have_button("Connect to X")
    expect(page).to have_link("Continue without connecting", href: dashboard_path)
    expect(page.text.index("Connect to X")).to be < page.text.index("Continue without connecting")
  end

  it "saves a connected or disconnected X account" do
    visit settings_social_connections_path
    expect(page).to have_button("Connect to X")
    expect(page).not_to have_button("Connect to YouTube")
    OmniAuth.config.mock_auth[:twitter] = OmniAuth::AuthHash.new JSON.parse(File.open("#{Rails.root}/spec/support/fixtures/twitter_omniauth.json").read)
    OmniAuth.config.before_callback_phase do |env|
      env["omniauth.params"] = { "state" => "link_twitter_account" }
    end
    click_on "Connect to X"
    expect(page).to have_button("Disconnect @squidarth from X")
    expect(seller.reload.twitter_handle).not_to be_nil
    click_on "Disconnect @#{seller.twitter_handle} from X"
    wait_for_ajax
    expect(seller.reload.twitter_handle).to be_nil
    expect(page).to have_button("Connect to X")
    OmniAuth.config.before_callback_phase = nil
  end

  it "shows Connect to YouTube when the youtube_connect flag is on" do
    Feature.activate_user(:youtube_connect, seller)
    visit settings_social_connections_path

    expect(page).to have_button("Connect to YouTube")
  end

  it "shows Connect to Instagram when the instagram_connect flag is on" do
    Feature.activate_user(:instagram_connect, seller)
    visit settings_social_connections_path

    expect(page).to have_button("Connect to Instagram")
  end
end
