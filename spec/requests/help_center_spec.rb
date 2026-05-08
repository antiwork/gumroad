# frozen_string_literal: true

require "spec_helper"

describe "Help Center", type: :system, js: true do
  let(:seller) { create(:named_seller) }

  describe "the user is unauthenticated" do
    it "shows the email support button" do
      visit "/help"

      expect(page).to have_link("Email support", href: "mailto:support@gumroad.com")
      expect(page).not_to have_link("Report a bug")
    end
  end

  describe "the user is authenticated" do
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
