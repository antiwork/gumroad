# frozen_string_literal: true

require "spec_helper"

describe "Profile edit shortcut", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:named_user) }

  before do
    sign_in seller
  end

  it "redirects subdomain /edit to profile settings" do
    get "/edit", headers: { "HOST" => URI.parse(seller.subdomain_with_protocol).host }

    expect(response).to redirect_to(profile_url(host: DOMAIN))
  end

  it "redirects root-domain /:username/edit to profile settings" do
    get "/#{seller.username}/edit", headers: { "HOST" => URI.parse(UrlService.domain_with_protocol).host }

    expect(response).to redirect_to(profile_url(host: DOMAIN))
  end

  it "returns 404 for an unknown username rather than an authorization error" do
    get "/nonexistent-username/edit", headers: { "HOST" => URI.parse(UrlService.domain_with_protocol).host }

    expect(response).to have_http_status(:not_found)
  end

  it "redirects the legacy /settings/profile path to /profile" do
    get "/settings/profile", headers: { "HOST" => URI.parse(UrlService.domain_with_protocol).host }

    expect(response).to have_http_status(:moved_permanently)
    expect(response).to redirect_to(profile_path)
  end

  it "preserves the section query param when redirecting the legacy /settings/profile path" do
    get "/settings/profile?section=abc123", headers: { "HOST" => URI.parse(UrlService.domain_with_protocol).host }

    expect(response).to have_http_status(:moved_permanently)
    expect(response).to redirect_to("/profile?section=abc123")
  end
end
