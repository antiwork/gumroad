# frozen_string_literal: true

require "spec_helper"

describe "Dashboard nav progressive disclosure", type: :system, js: true do
  let(:seller) { create(:user, name: "Gum") }

  before { login_as seller }

  # Core rows, in nav order. These are always visible for a seller who can reach them.
  def expect_core_rows_visible
    within "nav[aria-label='Main']" do
      expect(page).to have_link("Home")
      expect(page).to have_link("Products")
      expect(page).to have_link("Sales")
      expect(page).to have_link("Payouts")
      expect(page).to have_link("Discover")
    end
  end

  it "shows only the core rows to a new seller, with the rest behind Everything else" do
    visit dashboard_path

    expect_core_rows_visible

    within "nav[aria-label='Main']" do
      expect(page).to have_button("Everything else")

      expect(page).not_to have_link("Workflows")
      expect(page).not_to have_link("Emails")
      expect(page).not_to have_link("Affiliates")
      expect(page).not_to have_link("Checkout")
      expect(page).not_to have_link("Analytics")

      click_on "Everything else"

      expect(page).to have_link("Workflows")
      expect(page).to have_link("Emails")
      expect(page).to have_link("Affiliates")
      expect(page).to have_link("Checkout")
      expect(page).to have_link("Analytics")
    end
  end

  it "promotes a destination permanently once the seller visits it" do
    visit dashboard_path

    within "nav[aria-label='Main']" do
      click_on "Everything else"
      click_on "Workflows"
    end

    expect(page).to have_current_path(workflows_path)
    expect(seller.reload.promoted_nav_item_keys).to include "workflows"

    # Now a top-level row, on this page and on the next one.
    within "nav[aria-label='Main']" do
      expect(page).to have_link("Workflows")
    end

    visit dashboard_path
    within "nav[aria-label='Main']" do
      expect(page).to have_link("Workflows")
      expect(page).not_to have_link("Emails")
    end
  end

  it "keeps the row for the page being viewed out of the overflow" do
    visit workflows_path

    within "nav[aria-label='Main']" do
      expect(page).to have_link("Workflows", aria: { current: "page" })
    end
  end

  it "credits destinations the seller's store already uses, without a visit" do
    create(:workflow, seller:)
    create(:product, user: seller)

    visit dashboard_path

    within "nav[aria-label='Main']" do
      expect(page).to have_link("Workflows")
      expect(page).to have_link("Profile")
      expect(page).not_to have_link("Affiliates")
    end
  end

  it "drops Everything else once every destination is promoted" do
    seller.update!(promoted_nav_items: DashboardNav::PROMOTABLE_ITEMS)

    visit dashboard_path

    within "nav[aria-label='Main']" do
      expect(page).to have_link("Analytics")
      expect(page).not_to have_button("Everything else")
    end
  end

  context "on mobile", :mobile_view do
    it "fits the core rows without opening Everything else" do
      visit dashboard_path

      click_on "Toggle navigation"

      within "nav[aria-label='Main']" do
        expect(page).to have_link("Sales")
        expect(page).to have_link("Payouts")
        expect(page).to have_button("Everything else")
        expect(page).not_to have_link("Workflows")
      end
    end
  end
end
