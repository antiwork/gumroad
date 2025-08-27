# frozen_string_literal: true

require "spec_helper"

describe "Admin::SearchController Scenario", type: :system, js: true do
  describe "purchases" do
    describe "product_title_query" do
      let(:product_title_query) { "design" }
      let!(:product) { create(:product, name: "Graphic Design Course") }
      let!(:purchase) { create(:purchase, link: product, email: "user@example.com") }

      before do
        create(:purchase, link: create(:product, name: "Different Product"))
      end

      context "when query is set" do
        it "filters by product title" do
          # Create another purchase with same email and same product to avoid redirect
          create(:purchase, email: "user@example.com", link: product)

          visit admin_search_purchases_path(query: "user@example.com", product_title_query:)

          expect(page).to have_content("Graphic Design Course")
          expect(page).not_to have_content("Different Product")
        end

        it "shows clear button and clears product title filter" do
          # Create another purchase with same email and same product to avoid redirect
          create(:purchase, email: "user@example.com", link: product)

          visit admin_search_purchases_path(query: "user@example.com", product_title_query:)

          expect(page).to have_link("Clear filter")

          click_link("Clear filter")

          expect(current_url).to include("query=user@example.com")
          expect(current_url).not_to include("product_title_query")

          expect(page).to have_content("Graphic Design Course")
          expect(page).to have_content("Different Product")
        end
      end

      context "when query is not set" do
        it "ignores product_title_query" do
          visit admin_search_purchases_path(product_title_query:)

          expect(page).to have_content("Graphic Design Course")
          expect(page).to have_content("Different Product")
        end
      end
    end
  end
end
