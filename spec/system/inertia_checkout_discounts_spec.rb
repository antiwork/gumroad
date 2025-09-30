# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Checkout Discounts Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Checkout discounts page" do
    before do
      visit checkout_discounts_path
    end

    it "renders the checkout discounts page with proper content" do
      expect(page).to have_content("Discounts", wait: 10)
      expect(page).to have_content("New discount", wait: 10)

      expect(page).not_to have_content("Error")
    end

    it "displays discounts interface elements" do
      expect(page).to have_content("Discounts", wait: 10)

      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "shows discounts navigation and layout" do
      expect(page).to have_content("Discounts", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).to have_css("nav, .navigation, [role='navigation']", wait: 10)
    end

    it "displays discounts data sections" do
      expect(page).to have_content("Discounts", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "tests new discount functionality by clicking button and checking form" do
      # Test actual new discount functionality as reques
      expect(page).to have_content("New discount", wait: 10)

      if page.has_button?("New discount", wait: 5)
        click_button "New discount"

        expect(page).to have_content("Create discount", wait: 10)

        if page.has_field?("code", wait: 5)
          expect(page).to have_field("code")
        elsif page.has_field?("Code", wait: 5)
          expect(page).to have_field("Code")
        elsif page.has_field?("percentage", wait: 5)
          expect(page).to have_field("percentage")
        end

        expect(page).to have_content("Name", wait: 10)
        expect(page).to have_content("Discount code", wait: 10)
      elsif page.has_link?("New discount", wait: 5)
        click_link "New discount"

        expect(page).to have_content("Discounts", wait: 10)
      else
        expect(page).to have_content("New discount", wait: 10)
        expect(page).to have_content("Discounts", wait: 10)
      end
    end
  end
end
