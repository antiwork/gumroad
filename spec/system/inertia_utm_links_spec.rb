# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia UTM Links Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "UTM Links page" do
    before do
      visit dashboard_utm_links_path
    end

    it "renders the UTM links page with proper content" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).not_to have_content("Error")
    end

    it "displays UTM links interface elements" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end

    it "shows analytics navigation" do
      expect(page).to have_content("Analytics", wait: 10)
    end
  end
end
