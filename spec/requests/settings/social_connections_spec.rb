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
    expect(page).to have_button("Reconnect @squidarth from X")
    expect(page).to have_text("@squidarth")
    expect(page).not_to have_text("Not connected")
    expect(seller.reload.twitter_handle).not_to be_nil
    click_on "Open X connection menu"
    find("[role=menuitem]", text: "Disconnect").click
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
    expect(page).not_to have_button("Open X connection menu")
    click_on "Remove @old_handle from X"
    wait_for_ajax
    expect(seller.reload.twitter_handle).to be_nil
    expect(page).to have_text("Not connected")
  end

  # A read-only X token still reads as connected, so a seller sent here to fix one
  # needs a way to re-authorize that does not start by destroying the connection.
  it "offers Reconnect on a connected X account without requiring a disconnect first" do
    seller.update!(twitter_user_id: "123", twitter_handle: "squidarth",
                   twitter_oauth_token: "token", twitter_oauth_secret: "secret")
    visit settings_social_connections_path

    expect(page).to have_button("Reconnect @squidarth from X")
    expect(seller.reload.twitter_oauth_token).to eq("token")
  end

  # Disconnect is destructive and, for a seller who signed up with X, removes the identity
  # they log in with. It stays reachable but out of the way.
  it "keeps Disconnect one level in, behind the connection menu" do
    seller.update!(twitter_user_id: "123", twitter_handle: "squidarth",
                   twitter_oauth_token: "token", twitter_oauth_secret: "secret")
    visit settings_social_connections_path

    expect(page).not_to have_selector("[role=menuitem]", text: "Disconnect")
    click_on "Open X connection menu"
    find("[role=menuitem]", text: "Disconnect").click
    wait_for_ajax

    expect(seller.reload.twitter_oauth_token).to be_nil
    expect(page).to have_button("Connect to X")
  end

  context "arriving from a product's Share tab" do
    let(:product) { create(:product, user: seller, purchase_disabled_at: nil) }

    it "carries a return token so reconnecting lands back on the post" do
      visit settings_social_connections_path(social_connect_origin: "marketing",
                                             social_connect_product: product.unique_permalink)

      expect(page).to have_css("form[action*='social_connect_return=']", visible: :all)
    end

    it "mints no return token for a product the seller does not own" do
      other_product = create(:product, purchase_disabled_at: nil)
      visit settings_social_connections_path(social_connect_origin: "marketing",
                                             social_connect_product: other_product.unique_permalink)

      expect(page).to have_button("Connect to X")
      expect(page).not_to have_css("form[action*='social_connect_return=']", visible: :all)
    end
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
