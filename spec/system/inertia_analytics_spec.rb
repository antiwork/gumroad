# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Analytics Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
    allow_any_instance_of(AnalyticsPresenter).to receive(:page_props).and_return({
                                                                                   products: [],
                                                                                   country_codes: {},
                                                                                   state_names: []
                                                                                 })
  end

  describe "Analytics page" do
    before do
      visit analytics_path
    end

    it "renders the analytics dashboard with proper content" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).to have_content("Sales", wait: 10)
      expect(page).not_to have_content("Error")
    end

    it "displays analytics tabs and navigation" do
      expect(page).to have_content("Analytics", wait: 10)
    end

    it "shows analytics content area" do
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end
  end
end
