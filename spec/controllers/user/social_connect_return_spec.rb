# frozen_string_literal: true

require "spec_helper"

describe User::OmniauthCallbacksController do
  let(:seller) { create(:user) }
  let(:token) { SecureRandom.hex(32) }

  before do
    request.env["devise.mapping"] = Devise.mappings[:user]
    sign_in seller
    session[:social_connect_return] = { "token" => token, "user_id" => seller.id, "created_at" => Time.current.to_i }
    request.env["omniauth.params"] = { "social_connect_return" => token, "state" => "link_twitter_account" }
  end

  %w[youtube instagram twitter tiktok].each do |provider|
    it "returns #{provider} cancellation to onboarding and consumes intent" do
      request.env["omniauth.error.strategy"] = double(name: provider)
      get :failure
      expect(response).to redirect_to dashboard_path
      expect(flash[:alert]).to include("Couldn't connect")
      expect(session[:social_connect_return]).to be_nil
    end
  end

  it "returns successful X linking to onboarding without changing the linking operation" do
    expect(controller).to receive(:link_twitter_account)
    post :twitter
    expect(response).to redirect_to dashboard_path
    expect(session[:social_connect_return]).to be_nil
  end

  it "returns a successful YouTube connection to onboarding" do
    Feature.activate_user(:youtube_connect, seller)
    request.env["omniauth.auth"] = OmniAuth::AuthHash.new(credentials: { token: "test-token" })
    channel = { "id" => "example-channel", "handle" => "example" }
    allow(YoutubeChannelFetcher).to receive(:new).and_return(instance_double(YoutubeChannelFetcher, fetch: channel))
    post :youtube
    expect(response).to redirect_to dashboard_path
    expect(seller.reload.youtube_identity.channel_id).to eq("example-channel")
  end

  it "returns a successful Instagram connection to onboarding" do
    Feature.activate_user(:instagram_connect, seller)
    request.env["omniauth.auth"] = OmniAuth::AuthHash.new(uid: "example-id", credentials: { token: "test-token" })
    profile = { "user_id" => "example-id", "username" => "example" }
    allow(InstagramProfileFetcher).to receive(:new).and_return(instance_double(InstagramProfileFetcher, fetch: profile))
    post :instagram
    expect(response).to redirect_to dashboard_path
    expect(seller.reload.instagram_identity.instagram_user_id).to eq("example-id")
  end

  it "returns a successful TikTok connection to onboarding" do
    Feature.activate_user(:tiktok_connect, seller)
    request.env["omniauth.auth"] = OmniAuth::AuthHash.new(uid: "open-123", credentials: { token: "tiktok-token" })
    profile = { "open_id" => "open-123", "username" => "gumroad" }
    allow(TiktokProfileFetcher).to receive(:new).and_return(instance_double(TiktokProfileFetcher, fetch: profile))
    post :tiktok
    expect(response).to redirect_to dashboard_path
    expect(seller.reload.tiktok_identity.tiktok_open_id).to eq("open-123")
  end

  it "preserves the Social connections default without a session intent" do
    session.delete(:social_connect_return)
    post :youtube
    expect(response).to redirect_to settings_social_connections_path
  end

  it "does not accept an arbitrary URL as the return token" do
    request.env["omniauth.params"]["social_connect_return"] = "https://example.org/redirect"
    post :youtube
    expect(response).to redirect_to settings_social_connections_path
    expect(session[:social_connect_return]).to be_nil
  end

  it "ignores callback query parameters instead of trusting them as saved request params" do
    request.env["omniauth.params"] = {}
    post :youtube, params: { social_connect_return: token }
    expect(response).to redirect_to settings_social_connections_path
  end

  it "rejects an intent belonging to another user" do
    session[:social_connect_return]["user_id"] = create(:user).id
    post :youtube
    expect(response).to redirect_to settings_social_connections_path
    expect(session[:social_connect_return]).to be_nil
  end

  it "rejects an expired intent" do
    session[:social_connect_return]["created_at"] = 16.minutes.ago.to_i
    post :youtube
    expect(response).to redirect_to settings_social_connections_path
    expect(session[:social_connect_return]).to be_nil
  end

  it "rejects an intent after switching to another seller" do
    other = create(:user)
    create(:team_membership, user: seller, seller: other, role: TeamMembership::ROLE_ADMIN)
    cookies.encrypted[:current_seller_id] = other.id
    post :youtube
    expect(response).to redirect_to settings_social_connections_path
  end

  it "does not consume intent on an unrelated OAuth failure" do
    request.env["omniauth.error.strategy"] = double(name: "google_oauth2")
    get :failure, params: { error_description: "Unrelated failure" }
    expect(response).to redirect_to settings_payments_path
    expect(session[:social_connect_return]["token"]).to eq(token)
  end

  it "preserves login for a signed-out callback" do
    sign_out seller
    post :youtube
    expect(response).to redirect_to login_path
    expect(session[:social_connect_return]).to be_nil
  end

  it "does not alter Google sign-in referral behavior" do
    allow(User).to receive(:find_or_create_for_google_oauth2).and_return(seller)
    request.env["omniauth.params"]["referer"] = balance_path
    post :google_oauth2
    expect(response).to redirect_to balance_path
    expect(session[:social_connect_return]).to be_nil
  end
end
