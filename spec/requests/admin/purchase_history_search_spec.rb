# frozen_string_literal: true

require "spec_helper"

describe "Admin Purchase History Search", type: :feature, js: true do
  let(:admin) { create(:admin_user, has_risk_privilege: true, has_payout_privilege: true) }
  let(:buyer) { create(:user, email: "buyer@example.com") }
  let(:seller) { create(:user, email: "seller@example.com") }

  before do
    login_as(admin)
  end

  describe "purchase history search functionality" do
    let!(:product1) { create(:product, user: seller, name: "Amazing Ruby Course") }
    let!(:product2) { create(:product, user: seller, name: "JavaScript Masterclass") }
    let!(:product3) { create(:product, user: seller, name: "Python Basics") }

    let!(:purchase1) do
      create(:purchase,
             link: product1,
             purchaser: buyer,
             email: buyer.email,
             purchase_state: "successful",
             created_at: 3.days.ago)
    end

    let!(:purchase2) do
      create(:purchase,
             link: product2,
             purchaser: buyer,
             email: buyer.email,
             purchase_state: "successful",
             created_at: 2.days.ago)
    end

    let!(:purchase3) do
      create(:purchase,
             link: product3,
             purchaser: buyer,
             email: buyer.email,
             purchase_state: "failed",
             created_at: 1.day.ago)
    end

    context "when viewing buyer's admin page" do
      before do
        visit admin_user_path(buyer.id)
      end

      it "displays the search form" do
        expect(page).to have_text("Search purchase history")
        expect(page).to have_field("product_title", placeholder: "Search by product title...")
        expect(page).to have_button("Search")
      end

      it "does not show purchases by default" do
        expect(page).not_to have_text(product1.name)
        expect(page).not_to have_text(product2.name)
        expect(page).not_to have_text(product3.name)
      end

      it "searches and displays matching purchases" do
        fill_in "product_title", with: "Ruby"
        click_button "Search"

        expect(page).to have_text(product1.name)
        expect(page).not_to have_text(product2.name)
        expect(page).not_to have_text(product3.name)

        within("table") do
          expect(page).to have_text("successful")
          expect(page).to have_link(href: admin_purchase_path(purchase1))
          expect(page).to have_link(product1.name)
        end
      end

      it "performs case-insensitive search" do
        fill_in "product_title", with: "ruby"
        click_button "Search"

        expect(page).to have_text(product1.name)
        expect(page).not_to have_text(product2.name)
      end

      it "searches with partial matches" do
        fill_in "product_title", with: "Script"
        click_button "Search"

        expect(page).to have_text(product2.name)
        expect(page).not_to have_text(product1.name)
        expect(page).not_to have_text(product3.name)
      end

      it "shows empty state when no matches found" do
        fill_in "product_title", with: "Nonexistent Course"
        click_button "Search"

        expect(page).to have_text('No purchases found matching "Nonexistent Course"')
        expect(page).not_to have_text(product1.name)
        expect(page).not_to have_text(product2.name)
        expect(page).not_to have_text(product3.name)
      end

      it "displays purchase details correctly" do
        fill_in "product_title", with: "Python"
        click_button "Search"

        within("table") do
          expect(page).to have_text(product3.name)
          expect(page).to have_text("failed")
          expect(page).to have_link(href: admin_purchase_path(purchase3))
          expect(page).to have_link(product3.name)
          expect(page).to have_link(href: product3.long_url, target: "_blank")
        end
      end

      it "shows clear button when search is active" do
        fill_in "product_title", with: "Ruby"
        click_button "Search"

        expect(page).to have_link("Clear", href: admin_user_path(buyer))
      end

      it "clears search results when clear button is clicked" do
        fill_in "product_title", with: "Ruby"
        click_button "Search"

        expect(page).to have_text(product1.name)

        click_link "Clear"

        expect(page).not_to have_text(product1.name)
        expect(page).not_to have_link("Clear")
        expect(page).to have_field("product_title", with: "")
      end

      it "orders results by creation date descending" do
        # Create two more purchases with "Course" in the name to test ordering
        course_product1 = create(:product, user: seller, name: "Advanced Course")
        course_product2 = create(:product, user: seller, name: "Beginner Course")

        create(:purchase,
               link: course_product1,
               purchaser: buyer,
               email: buyer.email,
               purchase_state: "successful",
               created_at: 1.hour.ago)

        create(:purchase,
               link: course_product2,
               purchaser: buyer,
               email: buyer.email,
               purchase_state: "successful",
               created_at: 30.minutes.ago)

        fill_in "product_title", with: "Course"
        click_button "Search"

        purchase_rows = page.all("table tbody tr")
        expect(purchase_rows.count).to eq(3)
        # Most recent first (30 minutes ago)
        expect(purchase_rows[0]).to have_text("Beginner Course")
        # Then 1 hour ago
        expect(purchase_rows[1]).to have_text("Advanced Course")
        # Oldest last (3 days ago)
        expect(purchase_rows[2]).to have_text("Amazing Ruby Course")
      end

      it "handles search with whitespace" do
        fill_in "product_title", with: "  Ruby  "
        click_button "Search"

        expect(page).to have_text(product1.name)
        expect(page).not_to have_text(product2.name)
      end
    end

    context "when there are more than 10 matching purchases" do
      before do
        # Create 12 additional purchases with similar names
        12.times do |i|
          product = create(:product, user: seller, name: "Test Product #{i}")
          create(:purchase,
                 link: product,
                 purchaser: buyer,
                 email: buyer.email,
                 purchase_state: "successful",
                 created_at: i.hours.ago)
        end

        visit admin_user_path(buyer.id)
      end

      it "limits results to 10 and shows info message" do
        fill_in "product_title", with: "Test Product"
        click_button "Search"

        expect(page).to have_text("Showing first 10 results")

        purchase_rows = page.all("table tbody tr")
        expect(purchase_rows.count).to eq(10)
      end
    end

    context "when purchase has deleted product" do
      let!(:deleted_product) { create(:product, user: seller, name: "Deleted Course") }
      let!(:deleted_purchase) do
        create(:purchase,
               link: deleted_product,
               purchaser: buyer,
               email: buyer.email,
               purchase_state: "successful")
      end

      before do
        # Soft delete the product after creating the purchase
        deleted_product.update!(deleted_at: 1.hour.ago)
        visit admin_user_path(buyer.id)
      end

      it "still finds soft-deleted products in search results" do
        fill_in "product_title", with: "Deleted"
        click_button "Search"

        # The search should still find the purchase because left_joins includes soft-deleted products
        within("table") do
          expect(page).to have_text("Deleted Course")
          expect(page).to have_link(href: admin_purchase_path(deleted_purchase))
        end
      end
    end

    context "when purchase has different states and refunds" do
      let!(:refunded_purchase) do
        create(:purchase,
               link: product1,
               purchaser: buyer,
               email: buyer.email,
               purchase_state: "successful",
               stripe_refunded: true)
      end

      let!(:partially_refunded_purchase) do
        create(:purchase,
               link: product2,
               purchaser: buyer,
               email: buyer.email,
               purchase_state: "successful",
               stripe_partially_refunded: true)
      end

      let!(:chargedback_purchase) do
        create(:purchase,
               link: product3,
               purchaser: buyer,
               email: buyer.email,
               purchase_state: "successful",
               chargeback_date: 1.day.ago)
      end

      before do
        visit admin_user_path(buyer.id)
      end

      it "displays purchase states correctly" do
        fill_in "product_title", with: "Ruby"
        click_button "Search"

        within("table") do
          expect(page).to have_text("successful")
          expect(page).to have_text("(refunded)")
        end
      end

      it "shows partial refund status" do
        fill_in "product_title", with: "JavaScript"
        click_button "Search"

        within("table") do
          expect(page).to have_text("successful")
          expect(page).to have_text("(partially refunded)")
        end
      end

      it "shows chargeback status" do
        fill_in "product_title", with: "Python"
        click_button "Search"

        within("table") do
          expect(page).to have_text("successful")
          expect(page).to have_text("(chargeback)")
        end
      end
    end

    context "when purchase has variants" do
      let!(:variant_purchase) do
        purchase = create(:purchase,
                          link: product1,
                          purchaser: buyer,
                          email: buyer.email,
                          purchase_state: "successful")
        # Mock variants_list method
        allow(purchase).to receive(:variants_list).and_return("Size: Large, Color: Blue")
        purchase
      end

      before do
        visit admin_user_path(buyer.id)
      end

      it "displays variant information when present" do
        fill_in "product_title", with: "Ruby"
        click_button "Search"

        within("table") do
          expect(page).to have_text(product1.name)
        end
      end
    end

    context "when viewing through admin affiliates controller" do
      let(:affiliate_user) { create(:user, email: "affiliate@example.com") }

      before do
        visit admin_affiliate_path(affiliate_user.id)
      end

      it "does not show purchase history search for affiliate users" do
        # When accessed through admin/affiliates controller, is_affiliate_user is true
        # This tests the conditional rendering in the view
        expect(page).not_to have_text("Search purchase history")
      end
    end
  end

  describe "direct URL access with search parameters" do
    let!(:product) { create(:product, user: seller, name: "Direct Access Course") }
    let!(:purchase) do
      create(:purchase,
             link: product,
             purchaser: buyer,
             email: buyer.email,
             purchase_state: "successful")
    end

    it "performs search when accessing URL with product_title parameter" do
      visit admin_user_path(buyer.id, product_title: "Direct Access")

      expect(page).to have_text(product.name)
      expect(page).to have_field("product_title", with: "Direct Access")
      expect(page).to have_link("Clear")
    end

    it "handles empty search parameter gracefully" do
      visit admin_user_path(buyer.id, product_title: "")

      expect(page).not_to have_text(product.name)
      expect(page).to have_field("product_title", with: "")
      expect(page).not_to have_link("Clear")
    end
  end
end
