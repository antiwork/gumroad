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

    it "renders the checkout form page with proper content", skip: "Requires Braintree configuration" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).not_to have_content("Error")
    end

    it "displays form interface elements", skip: "Requires Braintree configuration" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end

    it "shows form navigation and layout", skip: "Requires Braintree configuration" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end
  end
end
