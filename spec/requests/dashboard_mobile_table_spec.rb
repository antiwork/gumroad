# frozen_string_literal: true

require "spec_helper"

describe "Dashboard - Mobile Table Labels", type: :system, js: true, mobile_view: true do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, name: "Test eBook", price_cents: 1000) }

  before do
    login_as(seller)

    # Create sales data for the product
    3.times do
      create(:purchase, link: product, created_at: Time.current)
    end

    # Mock analytics data to ensure predictable test values
    allow_any_instance_of(CreatorAnalytics::CachingProxy).to receive(:sales_by_product_id).and_return(
      product.id => {
        sales: 26,
        revenue_cents: 229_698,
        visits: 150,
        today_cents: 0,
        last_7_cents: 5000,
        last_30_cents: 20_000
      }
    )
  end

  it "shows Sales as a number in the best selling table" do
    visit(dashboard_path)

    expect(page).to have_text("Best selling")

    # Sales should display a number (26), not a dollar amount
    # Find the cell containing "Sales" label and verify it shows a number
    sales_cells = page.all("td", text: /Sales/i)
    within(sales_cells.first) do
      expect(page).to have_text("Sales")
      expect(page).to have_text("26")
      # Ensure it's not showing a dollar sign (which would indicate misalignment)
      expect(page.text.gsub("Sales", "").strip).not_to match(/^\$/)
    end
  end

  it "shows Revenue as a dollar amount in the best selling table" do
    visit(dashboard_path)

    expect(page).to have_text("Best selling")

    # Revenue should display a dollar amount ($2,296.98)
    revenue_cells = page.all("td", text: /Revenue/i)
    within(revenue_cells.first) do
      expect(page).to have_text("Revenue")
      expect(page).to have_text("$2,296", normalize_ws: true)
    end
  end

  it "shows Visits as a number in the best selling table" do
    visit(dashboard_path)

    expect(page).to have_text("Best selling")

    # Visits should display a number (150), not a dollar amount
    visits_cells = page.all("td", text: /Visits/i)
    within(visits_cells.first) do
      expect(page).to have_text("Visits")
      expect(page).to have_text("150")
      # Ensure it's not showing a dollar sign (which would indicate misalignment)
      expect(page.text.gsub("Visits", "").strip).not_to match(/^\$/)
    end
  end

  it "shows Today, Last 7 days, and Last 30 days as dollar amounts in the best selling table" do
    visit(dashboard_path)

    expect(page).to have_text("Best selling")

    # Today should show dollar amount
    today_cells = page.all("td", text: /Today/i)
    within(today_cells.first) do
      expect(page).to have_text("Today")
      expect(page).to have_text("$0", normalize_ws: true)
    end

    # Last 7 days should show dollar amount
    last_7_cells = page.all("td", text: /Last 7 days/i)
    within(last_7_cells.first) do
      expect(page).to have_text("Last 7 days")
      expect(page).to have_text("$50", normalize_ws: true)
    end

    # Last 30 days should show dollar amount
    last_30_cells = page.all("td", text: /Last 30 days/i)
    within(last_30_cells.first) do
      expect(page).to have_text("Last 30 days")
      expect(page).to have_text("$200", normalize_ws: true)
    end
  end
end
