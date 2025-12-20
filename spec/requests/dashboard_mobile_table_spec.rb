# frozen_string_literal: true

require "spec_helper"

describe "Dashboard - Mobile Table Labels", type: :system, js: true, mobile_view: true do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, name: "Test eBook", price_cents: 1000) }

  let!(:purchase_1) { create(:purchase_in_progress, seller: seller, link: product) }
  let!(:purchase_2) { create(:purchase_in_progress, seller: seller, link: product) }
  let!(:purchase_3) { create(:purchase_in_progress, seller: seller, link: product) }

  before do
    [purchase_1, purchase_2, purchase_3].each do |p|
      p.process!
      p.update_balance_and_mark_successful!
    end

    index_model_records(Purchase)
    index_model_records(Link)
    index_model_records(Balance)

    login_as(seller)
  end

  it "shows correct labels with proper data types in the best selling table", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    visit(dashboard_path)

    expect(page).to have_text("Best selling")

    sales_cells = page.all("td", text: /^Sales$/i)
    within(sales_cells.first) do
      expect(page).to have_text("Sales")
      expect(page).to have_text("3")
      expect(page.text.gsub("Sales", "").strip).not_to match(/^\$/)
    end

    revenue_cells = page.all("td", text: /^Revenue$/i)
    within(revenue_cells.first) do
      expect(page).to have_text("Revenue")
      expect(page).to have_text("$30", normalize_ws: true)
    end

    visits_cells = page.all("td", text: /^Visits$/i)
    within(visits_cells.first) do
      expect(page).to have_text("Visits")
      expect(page.text.gsub("Visits", "").strip).not_to match(/^\$/)
    end

    today_cells = page.all("td", text: /^Today$/i)
    within(today_cells.first) do
      expect(page).to have_text("Today")
      expect(page).to have_text("$30", normalize_ws: true)
    end

    last_7_cells = page.all("td", text: /Last 7 days/i)
    within(last_7_cells.first) do
      expect(page).to have_text("Last 7 days")
      expect(page).to have_text("$30", normalize_ws: true)
    end

    last_30_cells = page.all("td", text: /Last 30 days/i)
    within(last_30_cells.first) do
      expect(page).to have_text("Last 30 days")
      expect(page).to have_text("$30", normalize_ws: true)
    end
  end
end
