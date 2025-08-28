# frozen_string_literal: true

require "spec_helper"

describe "Admin::SearchController Scenario", type: :system, js: true do
  let(:admin) { create(:admin_user) }

  before do
    sign_in admin
  end

  describe "purchases" do
    describe "product_title_query" do
      let(:product_title_query) { "design" }
      let!(:product) { create(:product, name: "Graphic Design Course") }
      let!(:purchase) { create(:purchase, link: product, email: "user@example.com") }

      before do
        create(:purchase, link: create(:product, name: "Different Product"))
        # Create another purchase with same email and same product to avoid redirect
        create(:purchase, email: "user@example.com", link: product)
      end

      it "filters by product title" do
        visit admin_search_purchases_path(query: "user@example.com", product_title_query:)

        expect(page).to have_content("Graphic Design Course")
        expect(page).not_to have_content("Different Product")
      end

      it "shows clear button and clears product title filter" do
        different_product = create(:product, name: "Different Product")
        create(:purchase, email: "user@example.com", link: different_product)

        visit admin_search_purchases_path(query: "user@example.com", product_title_query:)

        expect(page).to have_link("Clear")

        click_link("Clear")

        expect(current_url).to include("query=user%40example.com")
        expect(current_url).not_to include("product_title_query")

        expect(page).to have_content("Graphic Design Course")
        expect(page).to have_content("Different Product")
      end
    end
  end
end
