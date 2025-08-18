# frozen_string_literal: true

require "spec_helper"

describe "Checkout offer codes", :js, type: :system do
  before do
    @product = create(:product, price_cents: 1000)
    @product2 = create(:product, price_cents: 1000)
  end

  it "only shows the discount code field for users that have it enabled" do
    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    visit "/l/#{@product2.unique_permalink}"
    add_to_cart(@product2)
    expect(page).to_not have_field("Discount code")

    create(:percentage_offer_code, products: [@product], amount_percentage: 15)
    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    expect(page).to_not have_field("Discount code")

    @product.user.update!(display_offer_code_field: true)
    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    expect(page).to have_field("Discount code")
  end

  it "does not show $0 discount codes that were added from the URL" do
    zero_percent_code = create(:percentage_offer_code, products: [@product], amount_percentage: 0, code: "0p")
    zero_cent_code = create(:percentage_offer_code, products: [@product], amount_percentage: 0, code: "0c")
    visit "/l/#{@product.unique_permalink}?offer_code=0p"
    add_to_cart(@product, offer_code: zero_percent_code)
    visit "/checkout?code=0c"
    expect(page).to_not have_text zero_percent_code.code
    expect(page).to_not have_text zero_cent_code.code

    actual_code = create(:percentage_offer_code, products: [@product], amount_percentage: 15)
    visit "/checkout?code=#{actual_code.code}"
    expect(page).to have_text(actual_code.code)
  end

  context "discount has already been applied to an item in the cart" do
    let(:seller) { create(:user, display_offer_code_field: true) }
    let!(:offer_code) { create(:percentage_offer_code, user: seller, universal: true, products: [], code: "everything") }
    let!(:product1) { create(:product, user: seller, name: "Product 1", price_cents: 1000) }
    let!(:product2) { create(:product, user: seller, name: "Product 2", price_cents: 2000) }

    it "applies the discount to items added to the cart" do
      visit product1.long_url
      add_to_cart(product1)
      fill_in "Discount code", with: "everything"
      click_on "Apply"
      expect(page).to have_text("Discounts everything US$-5", normalize_ws: true)

      visit product2.long_url
      add_to_cart(product2)
      expect(page).to have_text("Discounts everything US$-15", normalize_ws: true)

      check_out(product2)

      purchase1 = Purchase.last
      expect(purchase1.offer_code).to eq(offer_code)
      expect(purchase1.price_cents).to eq(500)
      expect(purchase1.link).to eq(product1)

      purchase2 = Purchase.second_to_last
      expect(purchase2.offer_code).to eq(offer_code)
      expect(purchase2.price_cents).to eq(1000)
      expect(purchase2.link).to eq(product2)
    end
  end

  describe "when product is removed from cart" do
    let(:seller) { create(:user, display_offer_code_field: true) }
    let!(:product1) { create(:product, user: seller, name: "Product 1", price_cents: 1000) }
    let!(:product2) { create(:product, user: seller, name: "Product 2", price_cents: 2000) }
    let!(:product3) { create(:product, user: seller, name: "Product 3", price_cents: 3000) }
    let(:product1_and_2_offer_code) { create(:percentage_offer_code, user: seller, products: [product1, product2], code: "product1_and_2_offer_code") }

    context "discount applies to all products" do
      let!(:offer_code) { create(:percentage_offer_code, user: seller, universal: true, products: [], code: "everything") }

      it "does not remove the discount" do
        visit product1.long_url
        add_to_cart(product1)
        fill_in "Discount code", with: "everything"
        click_on "Apply"
        expect(page).to have_text("Discounts everything US$-5", normalize_ws: true)

        visit product2.long_url
        add_to_cart(product2)
        expect(page).to have_text("Discounts everything US$-15", normalize_ws: true)

        visit product3.long_url
        add_to_cart(product3)
        expect(page).to have_text("Discounts everything US$-30", normalize_ws: true)

        within_cart_item "Product 3" do
          click_on "Remove"
        end
        wait_for_ajax

        expect(page).to have_text("Discounts everything US$-15", normalize_ws: true)
        check_out(product1)

        purchase1 = Purchase.last
        expect(purchase1.offer_code).to eq(offer_code)
        expect(purchase1.price_cents).to eq(500)
        expect(purchase1.link).to eq(product1)

        purchase2 = Purchase.second_to_last
        expect(purchase2.offer_code).to eq(offer_code)
        expect(purchase2.price_cents).to eq(1000)
        expect(purchase2.link).to eq(product2)
      end
    end

    context "discount applies to other products" do
      before do
        product1_and_2_offer_code
      end

      it "does not remove the discount" do
        visit product1.long_url
        add_to_cart(product1)
        fill_in "Discount code", with: "product1_and_2_offer_code"
        click_on "Apply"
        expect(page).to have_text("Discounts product1_and_2_offer_code US$-5", normalize_ws: true)

        visit product2.long_url
        add_to_cart(product2)
        expect(page).to have_text("Discounts product1_and_2_offer_code US$-15", normalize_ws: true)

        visit product3.long_url
        add_to_cart(product3)
        expect(page).to have_text("Discounts product1_and_2_offer_code US$-15", normalize_ws: true)

        within_cart_item "Product 2" do
          click_on "Remove"
        end
        wait_for_ajax

        within_cart_item "Product 3" do
          click_on "Remove"
        end
        wait_for_ajax

        expect(page).to have_text("Discounts product1_and_2_offer_code US$-5", normalize_ws: true)
        check_out(product1)

        purchase1 = Purchase.last
        expect(purchase1.offer_code).to eq(product1_and_2_offer_code)
        expect(purchase1.price_cents).to eq(500)
        expect(purchase1.link).to eq(product1)
      end
    end

    context "discount does not apply to other products" do
      before do
        product1_and_2_offer_code
      end

      it "removes the discount" do
        visit product1.long_url
        add_to_cart(product1)
        fill_in "Discount code", with: "product1_and_2_offer_code"
        click_on "Apply"
        expect(page).to have_text("Discounts product1_and_2_offer_code US$-5", normalize_ws: true)

        visit product2.long_url
        add_to_cart(product2)
        expect(page).to have_text("Discounts product1_and_2_offer_code US$-15", normalize_ws: true)

        visit product3.long_url
        add_to_cart(product3)
        expect(page).to have_text("Discounts product1_and_2_offer_code US$-15", normalize_ws: true)

        within_cart_item "Product 1" do
          click_on "Remove"
        end
        wait_for_ajax

        within_cart_item "Product 2" do
          click_on "Remove"
        end
        wait_for_ajax

        expect(page).not_to have_text("Discounts product1_and_2_offer_code", normalize_ws: true)
        expect(page).to_not have_field("Discount code")

        check_out(product3)

        purchase3 = Purchase.last
        expect(purchase3.offer_code).to be_nil
        expect(purchase3.price_cents).to eq(3000)
        expect(purchase3.link).to eq(product3)
      end
    end
  end
end
