# frozen_string_literal: true

require "spec_helper"

describe "Admin::PurchasesController Scenario", type: :system, js: true do
  let(:admin) { create(:admin_user) }
  let(:purchase) { create(:purchase, purchaser: create(:user), is_deleted_by_buyer: true) }

  before do
    login_as(admin)
  end

  describe "undelete functionality" do
    it "shows undelete button for deleted purchases" do
      visit admin_purchase_path(purchase.id)

      expect(page).to have_button("Undelete")
    end

    it "does not show undelete button for non-deleted purchases" do
      purchase.update!(is_deleted_by_buyer: false)
      visit admin_purchase_path(purchase.id)

      expect(page).not_to have_button("Undelete")
    end

    it "allows undeleting purchase" do
      expect(purchase.reload.is_deleted_by_buyer).to be(true)

      visit admin_purchase_path(purchase.id)
      click_on "Undelete"
      accept_browser_dialog
      wait_for_ajax

      expect(purchase.reload.is_deleted_by_buyer).to be(false)
      expect(page).to have_button("Undeleted!")
    end
  end

  describe "tip display" do
    it "shows tip amount correctly when purchase has a tip" do
      create(:tip, purchase: purchase, value_usd_cents: 500)

      visit admin_purchase_path(purchase.id)

      expect(page).to have_content("Tip $5", normalize_ws: true)
    end
  end
end
