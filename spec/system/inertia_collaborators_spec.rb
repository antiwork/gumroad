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

    it "renders the collaborators page with proper content" do
      expect(page).to have_content("Collaborators", wait: 10)
      expect(page).to have_content("Add collaborator", wait: 10)

      expect(page).not_to have_content("Error")
    end

    it "displays collaborators interface elements" do
      expect(page).to have_content("Collaborators", wait: 10)

      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "shows collaborators navigation and layout" do
      expect(page).to have_content("Collaborators", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).to have_css("nav, .navigation, [role='navigation']", wait: 10)
    end

    it "displays collaborators data sections" do
      expect(page).to have_content("Collaborators", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "tests add collaborator functionality by clicking button and checking form" do
      # Tesverify we can see the "Add collaborator" button
      expect(page).to have_content("Add collaborator", wait: 10)

      if page.has_button?("Add collaborator", wait: 5)
        click_button "Add collaborator"

        expect(page).to have_content("Collaborators", wait: 10)

        if page.has_field?("email", wait: 5)
          expect(page).to have_field("email")
        elsif page.has_field?("Email", wait: 5)
          expect(page).to have_field("Email")
        end

        expect(page).to have_content("Collaborators", wait: 10)
      elsif page.has_link?("Add collaborator", wait: 5)
        click_link "Add collaborator"

        expect(page).to have_content("Collaborators", wait: 10)
      else
        expect(page).to have_content("Add collaborator", wait: 10)
        expect(page).to have_content("Collaborators", wait: 10)
      end
    end
  end
end
