# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Products Page Scenario - Mobile", type: :system, js: true, mobile_view: true do
  let(:seller) { create(:named_seller) }

  before do
    login_as(seller)
  end

  it "shows Sales and Revenue labels in the products table footer" do
    create(:product, user: seller)

    visit(products_path)

    footer_rows = page.all("tfoot tr")
    within(footer_rows.first) do
      expect(page).to have_text("Totals")
      expect(page).to have_text("Sales 0", normalize_ws: true)
      expect(page).to have_text("Revenue $0", normalize_ws: true)
    end
  end

  it "shows Members and Revenue labels in the memberships table footer" do
    create(:subscription_product, user: seller)

    visit(products_path)

    footer_rows = page.all("tfoot tr")
    within(footer_rows.first) do
      expect(page).to have_text("Totals")
      expect(page).to have_text("Members 0", normalize_ws: true)
      expect(page).to have_text("Revenue $0", normalize_ws: true)
    end
  end
end
