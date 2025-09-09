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

  it "allows applications to access the mobile_api if they are allowed to (Production)" do
    stub_const("OauthApplication::MOBILE_API_OAUTH_APPLICATION_UID", @internal_app.uid)
    expect(Rails.env).to receive(:production?).and_return(true).at_least(1).times
    visit "/oauth/authorize?response_type=code&client_id=#{@internal_app.uid}&redirect_uri=#{Addressable::URI.escape(@internal_app.redirect_uri)}&scope=edit_products+mobile_api"
    expect(page).to have_content("Authorize #{@internal_app.name} to use your account?")
    expect(page).to have_content("Create new products and edit your existing products.")
    expect(page).to have_content("Mobile API")
    click_button "Authorize"
    expect(@internal_app.access_grants.count).to eq 1
    expect(@internal_app.access_grants.last.scopes.to_s).to eq "edit_products mobile_api"
  end

  it "allows applications to access the mobile_api if they are allowed to (Staging)" do
    stub_const("OauthApplication::MOBILE_API_OAUTH_APPLICATION_UID", @internal_app.uid)
    expect(Rails.env).to receive(:staging?).and_return(true).at_least(1).times
    visit "/oauth/authorize?response_type=code&client_id=#{@internal_app.uid}&redirect_uri=#{Addressable::URI.escape(@internal_app.redirect_uri)}&scope=edit_products+mobile_api"
    expect(page).to have_content("Authorize #{@internal_app.name} to use your account?")
    expect(page).to have_content("Create new products and edit your existing products.")
    expect(page).to have_content("Mobile API")
    click_button "Authorize"
    expect(@internal_app.access_grants.count).to eq 1
    expect(@internal_app.access_grants.last.scopes.to_s).to eq "edit_products mobile_api"
  end

  it "handles the situation where there is a nil oauth application in the pre_auth" do
    visit "/oauth/authorize?response_type=code&client_id=#{@app.uid + 'invalid'}&redirect_uri=#{Addressable::URI.escape(@app.redirect_uri)}&scope=mobile_api"
    expect(page).to have_content("Client authentication failed due to unknown client")
  end
end
