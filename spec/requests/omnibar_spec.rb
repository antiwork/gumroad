# frozen_string_literal: true

require "spec_helper"

describe "Dashboard omnibar", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product, user: seller, name: "Beautiful widget") }

  before { login_as seller }

  def open_omnibar
    within("nav[aria-label='Main']") { click_on "Search" }
  end

  def search_for(query)
    fill_in "Search products, sales and pages", with: query
  end

  # click_on only sees buttons, links, menu items and tabs; a result row is an option.
  def choose_result(text)
    find("[role=option]", text:).click
  end

  it "jumps to a page from the sidebar field without leaving the keyboard" do
    visit dashboard_path

    open_omnibar
    expect(page).to have_selector("input[role=combobox]:focus")
    search_for "payo"
    expect(page).to have_selector("[role=option][aria-selected=true]", text: "Payouts")
    send_keys(:enter)

    expect(page).to have_current_path(balance_path)
    expect(page).not_to have_selector("input[role=combobox]")
  end

  it "lists destinations that are still under Everything else" do
    visit dashboard_path

    within("nav[aria-label='Main']") { expect(page).not_to have_link("Workflows") }
    open_omnibar
    search_for "workfl"
    choose_result "Workflows"

    expect(page).to have_current_path(workflows_path)
  end

  it "finds a product by name and opens its edit page" do
    visit dashboard_path

    open_omnibar
    search_for "widg"
    choose_result "Beautiful widget"

    expect(page).to have_current_path(edit_link_path(product))
  end

  it "finds a sale by the buyer's email and opens it" do
    purchase = create(:purchase, link: product, seller:, full_name: "Ada Lovelace", email: "ada@example.com")
    index_model_records(Purchase)
    visit dashboard_path

    open_omnibar
    search_for "ada@example.com"
    choose_result "Ada Lovelace"

    expect(page).to have_current_path(customer_sale_path(purchase.external_id))
  end

  it "hands the query to the Sales page's own search" do
    visit dashboard_path

    open_omnibar
    search_for "nobody@example.com"
    expect(page).to have_text("No products or sales match “nobody@example.com”.")
    choose_result "Search sales for “nobody@example.com”"

    expect(page).to have_current_path(customers_path(query: "nobody@example.com"))
    expect(page).to have_section("No sales found")
  end

  it "opens with the keyboard shortcut from any dashboard page and closes with Escape" do
    visit products_path

    find("body").send_keys([ctrl_key, "k"])
    expect(page).to have_selector("input[role=combobox]:focus")

    send_keys(:escape)
    expect(page).not_to have_selector("input[role=combobox]")
  end

  it "puts focus back on the field in the sidebar when it closes" do
    visit dashboard_path

    open_omnibar
    send_keys(:escape)

    expect(page).to have_selector("nav[aria-label='Main'] button:focus", text: "Search")
  end

  context "on a phone", :mobile_view do
    it "opens from the icon in the header" do
      visit dashboard_path

      click_on "Search"
      search_for "widg"
      choose_result "Beautiful widget"

      expect(page).to have_current_path(edit_link_path(product))
    end
  end
end
