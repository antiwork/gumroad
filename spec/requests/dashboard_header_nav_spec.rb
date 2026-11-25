# frozen_string_literal: true

require "spec_helper"

describe "Dashboard header nav", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product, user: seller, name: "Beautiful widget") }

  before { login_as seller }

  def header
    find("nav[aria-label='Main']")
  end

  it "keeps the sidebar for a seller who is not on the trial" do
    visit dashboard_path

    within(header) do
      expect(page).to have_button("Everything else")
      expect(page).not_to have_button("More")
    end
  end

  context "for a seller on the trial" do
    before { Feature.activate_user(:dashboard_header_nav, seller) }

    it "puts the destinations, search, create and the account menu in one bar" do
      visit dashboard_path

      within(header) do
        expect(page).to have_link("Home")
        expect(page).to have_link("Products")
        expect(page).to have_link("Sales")
        expect(page).to have_button("Search")
        expect(page).to have_link("New product")
        expect(page).not_to have_button("Everything else")

        click_on "Products"
      end

      expect(page).to have_current_path(products_path)
      within(header) { expect(page).to have_selector("a[aria-current='page']", text: "Products") }
    end

    it "opens a destination that is not in the bar from More" do
      visit dashboard_path

      within(header) do
        expect(page).not_to have_link("Workflows")
        click_on "More"
        click_on "Workflows"
      end

      expect(page).to have_current_path(workflows_path)
    end

    it "creates something other than a product from the arrow beside New product" do
      visit dashboard_path

      within(header) do
        click_on "Create something else"
        click_on "New email"
      end

      expect(page).to have_current_path(new_email_path)
    end

    it "opens the search bar from the field in the middle" do
      visit dashboard_path

      within(header) { click_on "Search" }
      fill_in "Search products, sales and pages", with: "widg"
      find("[role=option]", text: "Beautiful widget").click

      expect(page).to have_current_path(edit_link_path(product))
    end

    it "logs out from the account menu at the right end" do
      visit dashboard_path

      within(header) do
        toggle_disclosure "#{seller.name} account"
        click_on "Logout"
      end

      expect(page).to have_content("Log in")
    end

    it "does not repeat New product in the page's own header" do
      visit products_path

      expect(page).to have_link("New product", count: 1)
    end

    context "on a phone", :mobile_view do
      it "keeps the drawer and the page's own New product button" do
        visit products_path

        expect(page).to have_button("Toggle navigation")
        expect(page).to have_link("New product", count: 1)
        click_on "Toggle navigation"
        expect(page).to have_link("Sales")
      end
    end
  end
end
