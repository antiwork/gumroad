# frozen_string_literal: true

require("spec_helper")

describe Oauth::AuthorizationsController, type: :system do
  before :each do
    visit "/"
    stub_const("DOMAIN", "gumroad.com")
    stub_const("VALID_REQUEST_HOSTS", ["gumroad.com"])
    @user = create(:named_user)
    @owner = create(:named_user)
    @app = create(:oauth_application, owner: @owner, redirect_uri: "http://" + DOMAIN + "/", confidential: false)
    @internal_app = create(:oauth_application, owner: @owner, redirect_uri: "http://" + DOMAIN + "/", confidential: false, scopes: Doorkeeper.configuration.scopes.to_a - Doorkeeper.configuration.default_scopes.to_a)
    login_as @user
    allow(Rails.env).to receive(:test?).and_return(false)
  end

  it "does not allow unauthorized apps to ask for mobile api (Production)" do
    expect(Rails.env).to receive(:production?).and_return(true).at_least(1).times
    visit "/oauth/authorize?response_type=code&client_id=#{@app.uid}&redirect_uri=#{Addressable::URI.escape(@app.redirect_uri)}&scope=mobile_api"
    expect(page).to have_content("The requested scope is invalid")
    expect(page).not_to have_content("Mobile API")
  end

  it "auto-authorizes the mobile app without showing the consent screen (Production)" do
    stub_const("OauthApplication::MOBILE_API_OAUTH_APPLICATION_UID", @internal_app.uid)
    expect(Rails.env).to receive(:production?).and_return(true).at_least(1).times
    visit "/oauth/authorize?response_type=code&client_id=#{@internal_app.uid}&redirect_uri=#{Addressable::URI.escape(@internal_app.redirect_uri)}&scope=edit_products+mobile_api"
    expect(page).not_to have_content("Authorize #{@internal_app.name} to use your account?")
    expect(@internal_app.access_grants.count).to eq 1
    expect(@internal_app.access_grants.last.scopes.to_s).to eq "edit_products mobile_api"
  end

  it "auto-authorizes the mobile app without showing the consent screen (Staging)" do
    stub_const("OauthApplication::MOBILE_API_OAUTH_APPLICATION_UID", @internal_app.uid)
    expect(Rails.env).to receive(:staging?).and_return(true).at_least(1).times
    visit "/oauth/authorize?response_type=code&client_id=#{@internal_app.uid}&redirect_uri=#{Addressable::URI.escape(@internal_app.redirect_uri)}&scope=edit_products+mobile_api"
    expect(page).not_to have_content("Authorize #{@internal_app.name} to use your account?")
    expect(@internal_app.access_grants.count).to eq 1
    expect(@internal_app.access_grants.last.scopes.to_s).to eq "edit_products mobile_api"
  end

  it "shows the consent screen for non-mobile OAuth applications (Production)" do
    stub_const("OauthApplication::MOBILE_API_OAUTH_APPLICATION_UID", @internal_app.uid)
    expect(Rails.env).to receive(:production?).and_return(true).at_least(1).times
    visit "/oauth/authorize?response_type=code&client_id=#{@app.uid}&redirect_uri=#{Addressable::URI.escape(@app.redirect_uri)}&scope=edit_products"
    expect(page).to have_content("Authorize #{@app.name} to use your account?")
  end

  it "handles the situation where there is a nil oauth application in the pre_auth" do
    visit "/oauth/authorize?response_type=code&client_id=#{@app.uid + 'invalid'}&redirect_uri=#{Addressable::URI.escape(@app.redirect_uri)}&scope=mobile_api"
    expect(page).to have_content("Client authentication failed due to unknown client")
  end

  it "preserves PKCE params through the consent form" do
    stub_const("OauthApplication::MOBILE_API_OAUTH_APPLICATION_UID", @internal_app.uid)
    code_challenge = Base64.urlsafe_encode64(Digest::SHA256.digest("test-verifier"), padding: false)

    visit "/oauth/authorize?response_type=code&client_id=#{@app.uid}&redirect_uri=#{Addressable::URI.escape(@app.redirect_uri)}&scope=edit_products&code_challenge=#{code_challenge}&code_challenge_method=S256"
    expect(page).to have_content("Authorize")
    click_button "Authorize"

    grant = @app.access_grants.last
    expect(grant.code_challenge).to eq(code_challenge)
    expect(grant.code_challenge_method).to eq("S256")
  end
end
