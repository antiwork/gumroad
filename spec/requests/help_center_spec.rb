# frozen_string_literal: true

require "spec_helper"

describe "Help Center", type: :system, js: true do
  let(:seller) { create(:named_seller) }

  before do
    allow(GlobalConfig).to receive(:get).with("RECAPTCHA_LOGIN_SITE_KEY")
    allow(GlobalConfig).to receive(:get).with("ENTERPRISE_RECAPTCHA_API_KEY")
    allow(GlobalConfig).to receive(:get).with("HELPER_WIDGET_SECRET").and_return("test_secret")
    allow(GlobalConfig).to receive(:get).with("HELPER_WIDGET_HOST").and_return("https://helper.test")

    stub_request(:post, "https://helper.test/api/widget/session")
      .to_return(
        status: 200,
        body: { token: "mock_helper_token" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  describe "the user is unauthenticated" do
    it "shows the email support button" do
      visit "/help"

      expect(page).to have_link("Email support", href: "mailto:support@gumroad.com")
      expect(page).not_to have_link("Report a bug")
    end
  end

  describe "the user is authenticated with Helper session" do
    before do
      sign_in seller
    end

    it "shows the email support button" do
      visit "/help"

      expect(page).to have_link("Email support", href: "mailto:support@gumroad.com")
      expect(page).not_to have_link("Report a bug")
    end
  end
end
