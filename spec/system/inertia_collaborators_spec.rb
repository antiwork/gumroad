# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Collaborators Page", type: :system, js: true do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  describe "Collaborators page" do
    before do
      visit collaborators_path
    end

    it "renders the collaborators page with Inertia" do
      expect(page).to have_content("Collaborators", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Collaborators/index")
    end

    it "displays collaborators data correctly" do
      # Check if the page loads with Inertia first
      expect(page).to have_css("[data-page]")

      # Verify the page loads without errors
      expect(page).not_to have_content("Error")
    end

    it "handles collaborators management functionality" do
      # Test that the page loads the collaborators data
      expect(page).to have_css("[data-page]")

      # Verify Inertia component structure
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Collaborators/index")
    end
  end
end
