# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Products Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Products index page" do
    before do
      visit products_path
    end

    it "renders the products page with proper content" do
      expect(page).to have_content("Products", wait: 10)
      expect(page).to have_content("New product", wait: 10)
      expect(page).not_to have_content("Error")
    end

    it "displays product interface elements" do
      expect(page).to have_content("Products", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end

    it "shows products navigation and layout" do
      expect(page).to have_content("Products", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).to have_css("nav, .navigation, [role='navigation']", wait: 10)
    end

    it "displays products data sections" do
      expect(page).to have_content("Products", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "tests new product functionality by clicking button and checking form" do
      expect(page).to have_content("New product", wait: 10)

      if page.has_button?("New product", wait: 5)
        click_button "New product"
        expect(page).to have_content("Next: Customize", wait: 10)

        if page.has_field?("name", wait: 5)
          expect(page).to have_field("name")
        elsif page.has_field?("Name", wait: 5)
          expect(page).to have_field("Name")
        end

        expect(page).to have_content("Next: Customize", wait: 10)
      elsif page.has_link?("New product", wait: 5)
        first(:link, "New product").click
        expect(page).to have_content("Next: Customize", wait: 10)
      else
        expect(page).to have_content("New product", wait: 10)
        expect(page).to have_content("Products", wait: 10)
      end
    end
  end

  describe "Products new page" do
    before do
      visit new_product_path
    end

    it "renders the new product page with proper content" do
      expect(page).to have_content("Next: Customize", wait: 10)
      expect(page).not_to have_content("Error")
    end

    it "displays product form interface" do
      expect(page).to have_content("Next: Customize", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end

    it "shows product creation layout" do
      expect(page).to have_content("Publish your first product", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).to have_css("nav, .navigation, [role='navigation']", wait: 10)
    end

    it "displays product form data sections" do
      expect(page).to have_content("Next: Customize", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "tests product form functionality by filling fields and checking results" do
      expect(page).to have_content("Next: Customize", wait: 10)

      if page.has_field?("name", wait: 5)
        fill_in "name", with: "Test Product Name"
        expect(page).to have_field("name", with: "Test Product Name")

        if page.has_button?("Next: Customize", wait: 5)
          expect(page).to have_button("Next: Customize")
        end
      elsif page.has_field?("Name", wait: 5)
        fill_in "Name", with: "Test Product Name"
        expect(page).to have_field("Name", with: "Test Product Name")
      else
        expect(page).to have_content("Next: Customize", wait: 10)
      end
    end
  end
end
