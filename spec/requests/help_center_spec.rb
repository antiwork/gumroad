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

    stub_request(:post, "https://helper.test/api/chat/conversation")
      .to_return(
        status: 200,
        body: { conversationSlug: "test-conversation-123" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:post, "https://helper.test/api/chat/conversation/test-conversation-123/message")
      .to_return(
        status: 200,
        body: { success: true }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  describe "the user is unauthenticated" do
    it "shows the contact support button and support modal" do
      visit "/help"

      expect(page).to have_button("Contact support")

      click_on "Contact support"

      expect(page).to have_content("How can we help you today?")
      expect(page).to have_field("Your email address")
      expect(page).to have_field("Subject")
      expect(page).to have_field("Tell us about your issue or question...")
    end

    it "successfully submits a support ticket form" do
      visit "/help"

      click_on "Contact support"

      fill_in "Your email address", with: "test@example.com"
      fill_in "Subject", with: "Need help with my account"
      fill_in "Tell us about your issue or question...", with: "I'm having trouble accessing my dashboard and need assistance."

      click_on "Send message"
      expect(page).to have_content("Your support ticket has been created successfully!")
      expect(page).not_to have_content("How can we help you today?")
    end
  end
end
