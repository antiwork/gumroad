# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Checkout Form Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Checkout form page" do
    before do
      visit checkout_form_path
    end

    it "renders the checkout form page with Inertia" do
      expect(page).to have_content("Checkout form", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Checkout/Form/index")
    end

    it "displays form data correctly" do
      # Check if the page loads with Inertia first
      expect(page).to have_css("[data-page]")

      # Verify the form props are passed correctly
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["props"]).to have_key("form_props")
    end

    it "handles form management functionality" do
      # Test that the page loads without errors
      expect(page).not_to have_content("Error")

      # Verify Inertia component structure
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Checkout/Form/index")
    end
  end
end
