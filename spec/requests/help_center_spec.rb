# frozen_string_literal: true

require "spec_helper"

describe "Help Center", type: :system, js: true do
  let(:seller) { create(:named_seller) }

  describe "the user is unauthenticated" do
    it "shows the email support button and the contact form trigger" do
      visit "/help"

      expect(page).to have_link("Email support", href: "mailto:support@gumroad.com")
      expect(page).to have_button("Contact support")
      expect(page).not_to have_link("Report a bug")
    end

    it "submits the contact form" do
      visit "/help"

      click_on "Contact support"

      fill_in "Your email", with: "buyer@example.com"
      select "Payouts", from: "What do you need help with?"
      fill_in "Message", with: "My payout hasn't arrived and it's been over a week now."

      click_on "Send message"

      expect(page).to have_text("Message sent!")
      expect(page).to have_text("buyer@example.com")
    end
  end

  describe "the user is authenticated" do
    before do
      sign_in seller
    end

    it "shows the email support button and prefills the contact form email" do
      visit "/help"

      expect(page).to have_link("Email support", href: "mailto:support@gumroad.com")
      expect(page).not_to have_link("Report a bug")

      click_on "Contact support"

      expect(page).to have_field("Your email", with: seller.email)
    end
  end
end
