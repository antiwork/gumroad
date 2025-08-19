# frozen_string_literal: true

require("spec_helper")

describe("Invalid offer-code usage from product page", type: :system, js: true) do
  describe "manually entered" do
    it "shows an error message when entering an invalid offer code and prevents purchase" do
      product = create(:product, price_cents: 300, user: create(:user, display_offer_code_field: true))
      create(:offer_code, products: [product], amount_cents: 300)
      visit "/l/#{product.unique_permalink}"

      add_to_cart(product)

      fill_in "Discount code", with: "invalid offer code"
      click_on "Apply"

      expect(page).to have_alert(text: "Sorry, the discount code you wish to use is invalid.")
    end

    it "shows an error message when entering a deleted offer code and prevents purchase" do
      product = create(:product, price_cents: 300, user: create(:user, display_offer_code_field: true))
      create(:offer_code, products: [product], amount_cents: 20, code: "unused_offer")
      offer_code = create(:offer_code, products: [product], amount_cents: 10)
      offer_code.mark_deleted!

      visit "/l/#{product.unique_permalink}"

      add_to_cart(product)

      fill_in "Discount code", with: offer_code.code
      click_on "Apply"

      expect(page).to have_alert(text: "Sorry, the discount code you wish to use is invalid.")
    end

    it "shows an error message when entering a sold out code and prevents purchase" do
      product = create(:product, price_cents: 300, user: create(:user, display_offer_code_field: true))
      offer_code = create(:offer_code, products: [product], amount_cents: 10, max_purchase_count: 0)
      visit "/l/#{product.unique_permalink}"

      add_to_cart(product)

      fill_in "Discount code", with: offer_code.code
      click_on "Apply"

      expect(page).to have_alert(text: "Sorry, the discount code you wish to use has expired.")
    end
  end

  describe "set via URL" do
    it "ignores a deleted offer code and allows purchase" do
      product = create(:product, price_cents: 300)
      offer_code = create(:offer_code, products: [product], amount_cents: 100)
      offer_code.mark_deleted!
      visit "/l/#{product.unique_permalink}/#{offer_code.code}"

      add_to_cart(product)

      wait_for_ajax
      expect(page).to(have_selector("[role='listitem'] [aria-label='Price']", text: "$3"))

      check_out(product)

      expect(Purchase.last.price_cents).to eq 300
    end

    it "ignores a sold out offer code and allows purchase" do
      product = create(:product, price_cents: 300)
      offer_code = create(:offer_code, products: [product], amount_cents: 10, max_purchase_count: 0)
      visit "/l/#{product.unique_permalink}/#{offer_code.code}"

      expect(page).to have_selector("[role='status']", text: "Sorry, the discount code you wish to use has expired.")
      add_to_cart(product)

      check_out(product)

      expect(Purchase.last.price_cents).to eq 300
    end
  end
end
