# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/creator_dashboard_page"

describe "Audience analytics", :js, :sidekiq_inline, :elasticsearch_wait_for_refresh, type: :system do
  let(:seller) { create(:user, created_at: 1.year.ago) }

  include_context "with switching account to user as admin for seller"

  it_behaves_like "creator dashboard page", "Analytics" do
    let(:path) { audience_dashboard_path }
  end

  it "shows the empty state" do
    visit audience_dashboard_path(from: "2023-12-01", to: "2023-12-31")
    expect(page).to have_text("You don't have any followers yet.")
    expect(page).not_to have_disclosure("12/1/2023 – 12/31/2023")
  end

  context "with followers" do
    before do
      recreate_model_index(ConfirmedFollowerEvent)
      create(:follower, user: seller, created_at: "2023-12-14 12:00:00", confirmed_at: "2023-12-14 12:00:00")
      create(:follower, user: seller, created_at: "2023-12-16 12:00:00", confirmed_at: "2023-12-16 12:00:00")
      create(:follower, user: seller, created_at: "2023-12-18 12:00:00", confirmed_at: "2023-12-18 12:00:00")
      unfollowed = create(:follower, user: seller, created_at: "2023-12-15 12:00:00", confirmed_at: "2023-12-15 12:00:00")
      unfollowed.update!(confirmed_at: nil, deleted_at: "2023-12-16 12:00:00")
    end

    it "calculates total stats" do
      visit audience_dashboard_path(from: "2023-12-01", to: "2023-12-31")
      within_section("Lifetime followers") { expect(page).to have_text("3") }
      within_section("New followers") { expect(page).to have_text("3") }

      toggle_disclosure "12/1/2023 – 12/31/2023"
      click_on "Custom range..."
      fill_in "From (including)", with: "12/13/2023"
      fill_in "To (including)", with: "12/14/2023"
      find("body").click # Blur the date field to trigger the update

      expect(page).to have_current_path(audience_dashboard_path(from: "2023-12-13", to: "2023-12-14"))
      within_section("Lifetime followers") { expect(page).to have_text("3") }
      within_section("New followers") { expect(page).to have_text("1") }
    end

    it "shows the chart" do
      visit audience_dashboard_path(from: "2023-12-01", to: "2023-12-31")
      expect(page).to have_css(".point", count: 31)

      chart = find(".chart")
      chart.hover
      expect(chart).to have_tooltip(text: "1 new follower\n1 follower removed\n2 total followers\nSaturday, December 16")

      toggle_disclosure "12/1/2023 – 12/31/2023"
      click_on "Custom range..."
      fill_in "From (including)", with: "12/17/2023"
      fill_in "To (including)", with: "12/18/2023"
      find("body").click # Blur the date field to trigger the update

      expect(page).to have_css(".point", count: 2)
      chart.hover
      expect(chart).to have_tooltip(text: "0 new followers\n2 total followers\nSunday, December 17")
    end
  end
end
