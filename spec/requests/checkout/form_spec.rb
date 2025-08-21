# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/creator_dashboard_page"

describe("Checkout form page", type: :system, js: true) do
  let(:seller) { create(:named_seller, recommendation_type: User::RecommendationType::OWN_PRODUCTS) }

  include_context "with switching account to user as admin for seller"

  it_behaves_like "creator dashboard page", "Checkout" do
    let(:path) { checkout_form_path }
  end

  describe "discounts" do
    it "allows updating the visibility of the offer code field" do
      visit checkout_form_path
      choose "Only if a discount is available"
      in_preview do
        expect(page).to have_field("Discount code")
      end
      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.display_offer_code_field).to eq(true)

      visit checkout_form_path
      choose "Never"
      in_preview do
        expect(page).to_not have_field("Discount code")
      end
      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.display_offer_code_field).to eq(false)
    end
  end

  describe "custom fields" do
    it "allows managing custom fields" do
      visit checkout_form_path
      click_on "Add custom field"
      select "Checkbox", from: "Type of field"

      click_on "Save changes"
      expect(find_field("Label")["aria-invalid"]).to eq "true"
      expect(page).to have_alert(text: "Please complete all required fields.")

      fill_in "Label", with: "You should totally check this - out!"
      in_preview do
        expect(page).to have_unchecked_field("You should totally check this - out!")
      end
      check "Required"

      click_on "Save changes"
      expect(find_field("Label")["aria-invalid"]).to eq "false"
      expect(find_field("Products")["aria-invalid"]).to eq "true"
      expect(page).to have_alert(text: "Please complete all required fields.")

      check "All products"
      click_on "Save changes"
      expect(find_field("Products")["aria-invalid"]).to eq "false"
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.custom_fields.count).to eq(1)
      field = seller.custom_fields.last
      expect(field.name).to eq "You should totally check this - out!"
      expect(field.type).to eq "checkbox"
      expect(field.required).to eq true
      expect(field.global).to eq true

      visit checkout_form_path
      select "Terms", from: "Type of field"
      expect(page).to have_field "Terms URL", with: "You should totally check this - out!"
      click_on "Save changes"
      expect(find_field("Terms URL")["aria-invalid"]).to eq "true"

      fill_in "Terms URL", with: "https://www.gumroad.com"
      in_preview do
        expect(page).to have_unchecked_field("I accept")
      end
      click_on "Save changes"
      expect(find_field("Terms URL")["aria-invalid"]).to eq "false"
      expect(page).to have_alert(text: "Changes saved!")
      expect(field.reload.type).to eq "terms"
      expect(field.name).to eq "https://www.gumroad.com"

      visit checkout_form_path
      within_section "Custom fields", section_element: :section do
        click_on "Remove"
      end
      in_preview do
        expect(page).to_not have_field("I accept")
      end
      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")
      expect(page).to_not have_field("Type of field")
      expect(seller.custom_fields.count).to eq(0)
    end

    context "when a product is archived" do
      let(:product1) { create(:product, name: "Product 1", user: seller, price_cents: 1000, archived: true) }
      let(:product2) { create(:product, name: "Product 2", user: seller, price_cents: 500) }

      it "doens't include the product in the product list" do
        visit checkout_form_path
        click_on "Add custom field"

        find(:label, "Products").click
        expect(page).to have_combo_box "Products", options: ["Product 2"]
      end
    end
  end

  describe "more like this" do
    it "allows updating the recommendation type" do
      visit checkout_form_path
      in_preview do
        expect(page).to have_section("Customers who bought this item also bought")
        within_section("Customers who bought this item also bought") do
          expect(page).to have_section("A Sample Product")
        end
      end
      choose "Don't recommend any products"
      in_preview do
        expect(page).to_not have_section("Customers who bought this item also bought")
      end
      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.recommendation_type).to eq(User::RecommendationType::NO_RECOMMENDATIONS)

      visit checkout_form_path
      choose "Recommend my products"
      in_preview do
        expect(page).to have_section("Customers who bought this item also bought")
        within_section("Customers who bought this item also bought") do
          expect(page).to have_section("A Sample Product")
        end
      end
      click_on "Save changes"
      wait_for_ajax
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.recommendation_type).to eq(User::RecommendationType::OWN_PRODUCTS)

      choose "Recommend all products and earn a commission with Gumroad Affiliates"
      in_preview do
        expect(page).to have_section("Customers who bought this item also bought")
        within_section("Customers who bought this item also bought") do
          expect(page).to have_section("A Sample Product")
        end
      end
      click_on "Save changes"
      wait_for_ajax
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.recommendation_type).to eq(User::RecommendationType::GUMROAD_AFFILIATES_PRODUCTS)

      choose "Recommend my products and products I'm an affiliate of"
      in_preview do
        expect(page).to have_section("Customers who bought this item also bought")
        within_section("Customers who bought this item also bought") do
          expect(page).to have_section("A Sample Product")
        end
      end
      click_on "Save changes"
      wait_for_ajax
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.recommendation_type).to eq(User::RecommendationType::DIRECTLY_AFFILIATED_PRODUCTS)
    end
  end

  describe "tipping" do
    it "allows updating the tipping setting" do
      visit checkout_form_path

      find_field("Allow customers to add tips to their orders", checked: false).check
      in_preview do
        expect(page).to have_text("Add a tip")
        expect(page).to have_radio_button("0%", checked: true)
        expect(page).to have_radio_button("10%", checked: false)
        expect(page).to have_radio_button("20%", checked: false)
        expect(page).to have_radio_button("Other", checked: false)
      end
      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.tipping_enabled).to eq(true)

      refresh
      in_preview do
        expect(page).to have_text("Add a tip")
        expect(page).to have_radio_button("0%", checked: true)
        expect(page).to have_radio_button("10%", checked: false)
        expect(page).to have_radio_button("20%", checked: false)
        expect(page).to have_radio_button("Other", checked: false)
      end
      find_field("Allow customers to add tips to their orders", checked: true).uncheck
      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.tipping_enabled).to eq(false)
    end
  end

  describe "preview" do
    context "when the user has alive products" do
      let!(:product1) { create(:product, user: seller, name: "Product 1") }
      let!(:product2) { create(:product, user: seller, name: "Product 2") }

      it "displays the product that was created first" do
        visit checkout_form_path

        in_preview do
          within_cart_item "Product 1" do
            expect(page).to have_text("Seller")
            expect(page).to have_text("Qty: 1")
            expect(page).to have_text("US$1")
          end
        end
      end
    end

    context "when the user has no products" do
      it "displays a placeholder product" do
        visit checkout_form_path

        in_preview do
          within_cart_item "A Sample Product" do
            expect(page).to have_text("Gumroadian")
            expect(page).to have_text("Qty: 1")
            expect(page).to have_text("US$1")
          end
        end
      end
    end
  end
end
