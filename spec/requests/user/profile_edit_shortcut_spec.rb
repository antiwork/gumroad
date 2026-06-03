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

    expect(response).to redirect_to(settings_profile_url(host: DOMAIN))
  end

  it "redirects root-domain /:username/edit to profile settings" do
    get "/#{seller.username}/edit", headers: { "HOST" => URI.parse(UrlService.domain_with_protocol).host }

    expect(response).to redirect_to(settings_profile_url(host: DOMAIN))
  end
end
