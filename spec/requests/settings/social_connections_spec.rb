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

  it "renders connect controls for the owner and carries the onboarding return token" do
    visit settings_social_connections_path(social_connect_origin: "onboarding")

    expect(page).to have_text("Social connections")
    expect(page).to have_text("Connecting a social account is optional")
    expect(page).to have_button("Connect to X")
    expect(page).to have_text("Not connected")
    expect(page).to have_css("form[action*='social_connect_return=']", visible: :all)
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
    expect(page).to have_text("@squidarth")
    expect(page).not_to have_text("Not connected")
    expect(seller.reload.twitter_handle).not_to be_nil
    click_on "Disconnect @#{seller.twitter_handle} from X"
    wait_for_ajax
    expect(seller.reload.twitter_handle).to be_nil
    expect(page).to have_button("Connect to X")
    OmniAuth.config.before_callback_phase = nil
  end

  it "lets the owner remove a legacy hand-typed X handle and still offers Connect" do
    seller.update!(twitter_handle: "old_handle", twitter_user_id: nil)
    visit settings_social_connections_path

    expect(page).to have_text("@old_handle was added by hand and is not verified.")
    expect(page).to have_button("Connect to X")
    expect(page).not_to have_button("Disconnect @old_handle from X")
    click_on "Remove @old_handle from X"
    wait_for_ajax
    expect(seller.reload.twitter_handle).to be_nil
    expect(page).to have_text("Not connected")
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

  it "shows Connect to TikTok when the tiktok_connect flag is on" do
    Feature.activate_user(:tiktok_connect, seller)
    visit settings_social_connections_path

    expect(page).to have_button("Connect to TikTok")
  end
end
