# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Audience Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Audience page" do
    before do
      visit audience_dashboard_path
    end

    it "renders the audience page with proper content" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).to have_content("Following", wait: 10)
      expect(page).not_to have_content("Error")
    end

    it "displays audience interface elements" do
      expect(page).to have_content("Following", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end

    it "shows audience navigation and layout" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end
  end
end
