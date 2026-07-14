# frozen_string_literal: true

require("spec_helper")

describe("Multiple quantity purchases from product page", type: :system, js: true) do
  describe "multiple quantities" do
    before do
      @product = create(:physical_product, price_cents: 200)
    end

    it "charges the correct amount for PWYW products" do
      @product.price_range = "3+"
      @product.customizable_price = true
      @product.save

      visit "/l/#{@product.unique_permalink}"

      add_to_cart(@product, quantity: 2, pwyw_price: 10)

      check_out(@product)

      expect(Purchase.last.price_cents).to eq 2000
      expect(Purchase.last.fee_cents).to eq 338
      expect(Purchase.last.quantity).to eq 2
    end

    it "does not complete the purchase if amount is less than minimum for PWYW product" do
      @product.price_range = "3+"
      @product.customizable_price = true
      @product.save

      visit "/l/#{@product.unique_permalink}"

      fill_in "Name a fair price:", with: "1"
      click_on("I want this!")

      expect(find_field("Name a fair price")["aria-invalid"]).to eq("true")
    end

    it "works with multiple quantities" do
      visit "/l/#{@product.unique_permalink}"
      add_to_cart(@product, quantity: 2)
      check_out(@product)

      expect(Purchase.last.price_cents).to eq 400
      expect(Purchase.last.fee_cents).to eq 132
      expect(Purchase.last.quantity).to eq 2
    end

    it "does not process payment if not enough variants available" do
      variant_category = create(:variant_category, link: @product, title: "type")
      variants = [["type 1", 150], ["type 2", 200], ["type 3", 300]]
      variants.each do |name, price_difference_cents|
        create(:variant, variant_category:, name:, price_difference_cents:, max_purchase_count: 2)
      end
      Product::SkusUpdaterService.new(product: @product).perform

      visit "/l/#{@product.unique_permalink}"

      add_to_cart(@product, quantity: 2, option: "type 1")
      Sku.not_is_default_sku.first.update_attribute(:max_purchase_count, 1)

      check_out(@product, error: "You have chosen a quantity that exceeds what is available")
    end

    it "displays and successfully charges the correct amount after offer code, mimicking backend's quantity x offer code application" do
      @offer_code = create(:percentage_offer_code, products: [@product], amount_percentage: 15)
      @product.update!(price_cents: 29_95)
      @product.user.update!(display_offer_code_field: true)

      visit "/l/#{@product.unique_permalink}"

      add_to_cart(@product, quantity: 7)

      fill_in "Discount code", with: @offer_code.code
      click_on "Apply"
      wait_for_ajax

      expect(page).to have_text("Total US$178.22", normalize_ws: true)

      check_out(@product)
    end

    it "does not process the payment if not enough offer codes available" do
      offer_code = create(:percentage_offer_code, products: [@product], amount_percentage: 50, max_purchase_count: 3)
      @product.save
      @product.user.update!(display_offer_code_field: true)

      visit "/l/#{@product.unique_permalink}"

      add_to_cart(@product, quantity: 2)
      offer_code.update_attribute(:max_purchase_count, 1)

      fill_in "Discount code", with: offer_code.code
      click_on "Apply"
      expect(page).to have_alert("Sorry, the discount code you are using is invalid for the quantity you have selected.")
    end

    it "does not process payment if not enough products available" do
      visit "/l/#{@product.unique_permalink}"
      add_to_cart(@product, quantity: 2)
      @product.update_attribute(:max_purchase_count, 1)
      check_out(@product, error: "You have chosen a quantity that exceeds what is available.")
    end
  end
end
