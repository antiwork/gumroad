# frozen_string_literal: true

require("spec_helper")

describe("Zero-discount offer-code usage from product page", type: :system, js: true) do
  context "manually set" do
    it "does not error when entering a $0 offer code and allows purchase" do
      product = create(:product, price_cents: 300, user: create(:user, display_offer_code_field: true))
      offer_code = create(:offer_code, products: [product], amount_cents: 0)
      visit "/l/#{product.unique_permalink}"


      add_to_cart(product)
      check_out(product, offer_code: offer_code.code)

      purchase = Purchase.last
      expect(purchase.price_cents).to eq 300
      expect(purchase.offer_code).to eq offer_code
    end

    it "does not error when entering a 0% offer code and allows purchase" do
      product = create(:product, price_cents: 300, user: create(:user, display_offer_code_field: true))
      offer_code = create(:offer_code, products: [product], amount_cents: nil, amount_percentage: 0)
      visit "/l/#{product.unique_permalink}"

      add_to_cart(product)
      check_out(product, offer_code: offer_code.code)

      purchase = Purchase.last
      expect(purchase.price_cents).to eq 300
      expect(purchase.offer_code).to eq offer_code
    end
  end

  context "set via URL" do
    it "applies a $0 offer code and allows purchase" do
      product = create(:product, price_cents: 300)
      offer_code = create(:offer_code, products: [product], amount_cents: 0)
      visit "/l/#{product.unique_permalink}/#{offer_code.code}"

      add_to_cart(product, offer_code:)

      wait_for_ajax
      expect(page).to have_text("Total US$3", normalize_ws: true)

      check_out(product)

      purchase = Purchase.last
      expect(purchase.price_cents).to eq 300
      expect(purchase.offer_code).to eq offer_code
    end

    it "applies a 0% offer code and allows purchase" do
      product = create(:product, price_cents: 300)
      offer_code = create(:percentage_offer_code, products: [product], amount_percentage: 0)
      visit "/l/#{product.unique_permalink}/#{offer_code.code}"

      add_to_cart(product, offer_code:)

      wait_for_ajax
      expect(page).to have_text("Total US$3", normalize_ws: true)

      check_out(product)

      purchase = Purchase.last
      expect(purchase.price_cents).to eq 300
      expect(purchase.offer_code).to eq offer_code
    end
  end
end
