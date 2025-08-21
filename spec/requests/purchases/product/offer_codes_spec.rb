# frozen_string_literal: true

require("spec_helper")

describe("Offer-code usage from product page", type: :system, js: true) do
  it "accepts an offer code that's larger than the price of the product" do
    product = create(:product, price_cents: 300)
    offer_code = create(:offer_code, products: [product], amount_cents: 500)
    visit URI::DEFAULT_PARSER.escape("/l/#{product.unique_permalink}/#{offer_code.code}")

    add_to_cart(product, offer_code:)
    check_out(product, is_free: true)

    purchase = Purchase.last
    discount = purchase.purchase_offer_code_discount
    expect(purchase.price_cents).to eq 0
    expect(purchase.offer_code).to eq offer_code
    expect(discount.offer_code_amount).to eq 500
    expect(discount.offer_code_is_percent).to eq false
    expect(discount.pre_discount_minimum_price_cents).to eq 300
  end

  it "accepts a non-ascii offer code from a shared URL" do
    product = create(:product, price_cents: 350)
    variant_category_1 = create(:variant_category, link: product)
    %w[Base Premium].each_with_index { |name, index| create(:variant, name:, variant_category: variant_category_1, price_difference_cents: 100 * index) }
    offer_code = create(:offer_code, products: [product], amount_cents: 350, name: "ÕËëæç")
    visit URI::DEFAULT_PARSER.escape("/l/#{product.unique_permalink}/#{offer_code.code}")

    expect(page).to have_selector("[itemprop='price']", text: "$3.50 $0", visible: false)

    expect(page).to have_selector("[role='status']", text: "$3.50 off will be applied at checkout (Code #{offer_code.code.upcase})")
    expect(page).to have_radio_button("Base", text: "$3.50 $0")
    expect(page).to have_radio_button("Premium", text: "$4.50 $1")

    add_to_cart(product, offer_code:, option: "Base")
    check_out(product, is_free: true)

    expect(Purchase.last.price_cents).to eq 0
  end

  it "recognizes a plain ascii offer code from a shared URL" do
    product = create(:product, price_cents: 300)
    offer_code = create(:offer_code, products: [product], amount_cents: 100, name: "boringcode")
    visit "/l/#{product.unique_permalink}/#{offer_code.code}"

    add_to_cart(product, offer_code:)
    check_out(product)

    expect(Purchase.last.price_cents).to eq 200
    expect(Purchase.last.total_transaction_cents).to eq 200
  end

  it "does not treat a trailing slash in the URL as an offer code" do
    link = create(:product, price_cents: 300)
    visit "/l/#{link.unique_permalink}/"

    add_to_cart(link)
    check_out(link)

    expect(Purchase.last.price_cents).to eq 300
    expect(Purchase.last.total_transaction_cents).to eq 300
  end

  it "recognizes a universal offer code from a shared URL" do
    link = create(:product, price_cents: 300)
    offer_code = create(:universal_offer_code, user: link.user, amount_cents: 150, name: "universalcode")
    visit "/l/#{link.unique_permalink}/#{offer_code.code}"

    add_to_cart(link, offer_code:)
    check_out(link)

    expect(Purchase.last.price_cents).to eq(150)
    expect(Purchase.last.total_transaction_cents).to eq(150)
  end

  it "recognizes a universal offer code from a username.gumroad.com based share URL" do
    link = create(:product, price_cents: 300)
    offer_code = create(:universal_offer_code, user: link.user, amount_cents: 150, name: "universalcode")
    visit "#{link.user.subdomain_with_protocol}/l/#{link.unique_permalink}/#{offer_code.code}"

    add_to_cart(link, offer_code:)
    check_out(link)

    expect(Purchase.last.price_cents).to eq(150)
    expect(Purchase.last.total_transaction_cents).to eq(150)
  end

  it "calculates percentage discounts from non-even amounts properly and goes through" do
    product = create(:product, price_cents: 4999)
    offer_code = create(:percentage_offer_code, products: [product], amount_percentage: 50)
    visit URI::DEFAULT_PARSER.escape("/l/#{product.unique_permalink}/#{offer_code.code}")

    add_to_cart(product, offer_code:)

    expect(page).to have_text("Total US$24.99", normalize_ws: true)

    check_out(product)

    purchase = Purchase.last
    discount = purchase.purchase_offer_code_discount
    expect(purchase).to be_successful
    expect(purchase.price_cents).to eq 2499
    expect(purchase.offer_code).to eq offer_code
    expect(discount.offer_code_amount).to eq 50
    expect(discount.offer_code_is_percent).to eq true
    expect(discount.pre_discount_minimum_price_cents).to eq 4999
  end

  it "handles rounding edge cases properly" do
    product = create(:product, price_cents: 1395)
    offer_code = create(:percentage_offer_code, products: [product], amount_percentage: 70)
    visit URI::DEFAULT_PARSER.escape("/l/#{product.unique_permalink}/#{offer_code.code}")

    add_to_cart(product, offer_code:)

    expect(page).to have_text("Total US$4.19", normalize_ws: true)

    check_out(product)

    purchase = Purchase.last
    expect(purchase.price_cents).to eq 419
    expect(purchase.offer_code).to eq offer_code
  end

  it "doesn't render the offer code status for $0 offer codes" do
    product = create(:product, price_cents: 300)
    offer_code = create(:offer_code, products: [product], amount_cents: 0)
    visit "#{product.long_url}/#{offer_code.code}"
    expect(page).not_to have_selector("[role='status']")
  end

  it "removes existing discount codes that only apply to the same products as the new discount code" do
    seller = create(:user, display_offer_code_field: true)
    product1 = create(:product, user: seller)
    product2 = create(:product, user: seller)
    product3 = create(:product, user: seller)
    offer_code1 = create(:offer_code, code: "code1", products: [product1, product3])
    offer_code2 = create(:offer_code, code: "code2", products: [product1, product2])

    visit "#{product1.long_url}/#{offer_code1.code}"
    add_to_cart(product1, offer_code: offer_code1)

    visit product2.long_url
    add_to_cart(product2)

    fill_in "Discount code", with: offer_code2.code
    click_on "Apply"
    expect(page).to_not have_selector("[aria-label='Discount code']", text: offer_code1.code)
    expect(page).to have_selector("[aria-label='Discount code']", text: offer_code2.code)

    visit product3.long_url
    add_to_cart(product3)
    fill_in "Discount code", with: offer_code1.code
    click_on "Apply"
    expect(page).to have_selector("[aria-label='Discount code']", text: offer_code1.code)
    expect(page).to have_selector("[aria-label='Discount code']", text: offer_code2.code)
  end

  context "when the product has quantity enabled" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller, price_cents: 1000, quantity_enabled: true) }
    let(:offer_code) { create(:offer_code, user: seller, products: [product]) }

    it "applies the offer code" do
      visit "#{product.long_url}/#{offer_code.code}?quantity=2"
      expect(page).to have_field("Quantity", with: "2")

      fill_in "Quantity", with: 3
      expect(page).to have_field("Quantity", with: "3")

      add_to_cart(product, offer_code:, quantity: 3)
      check_out(product)

      purchase = Purchase.last
      expect(purchase.quantity).to eq(3)
      expect(purchase.price_cents).to eq(2700)
    end
  end

  context "when an offer code changes after it has been applied to the cart" do
    it "fails the purchase but updates the offer code" do
      product = create(:product, price_cents: 1000)
      offer_code = create(:offer_code, products: [product])

      visit "#{product.long_url}/#{offer_code.code}"
      add_to_cart(product, offer_code:)
      offer_code.update!(amount_cents: 200)
      check_out(product, error: "The price just changed! Refresh the page for the updated price.")
      visit checkout_index_path
      check_out(product)
    end
  end

  context "when an offer code is removed after it has been applied to the cart" do
    it "fails the purchase but removes the offer code" do
      product = create(:product, price_cents: 1000)
      offer_code = create(:offer_code, products: [product])

      visit "#{product.long_url}/#{offer_code.code}"
      add_to_cart(product, offer_code:)
      offer_code.mark_deleted!
      check_out(product, error: "Sorry, the discount code you wish to use is invalid.")
      visit checkout_index_path
      expect(page).to_not have_selector("[aria-label='Discount code']", text: offer_code.code)
      expect(page).to have_text("Total US$10", normalize_ws: true)
      check_out(product)
      expect(Purchase.last.price_cents).to eq(1000)
    end
  end

  context "when the product is PWYW" do
    before do
      @product = create(:product, price_cents: 2000, customizable_price: true)
    end

    context "absolute offer code" do
      before do
        @offer_code = create(:offer_code, products: [@product], amount_cents: 1000)
      end

      it "accepts the offer code and takes the PWYW price as the post-discount price" do
        visit "#{@product.long_url}/#{@offer_code.code}"
        add_to_cart(@product, pwyw_price: 10.44, offer_code: @offer_code)
        check_out(@product)
      end
    end

    context "percentage offer code" do
      before do
        @offer_code = create(:percentage_offer_code, products: [@product], amount_percentage: 20)
      end

      it "accepts the offer code and takes the PWYW price as the post-discount price" do
        visit "#{@product.long_url}/#{@offer_code.code}"
        add_to_cart(@product, pwyw_price: 16.44, offer_code: @offer_code)
        check_out(@product)
      end
    end
  end

  context "when purchasing a product with a quantity larger than 1" do
    it "displays the correct discount and the purchase succeeds" do
      product = create(:product, price_cents: 1000, quantity_enabled: true)
      offer_code = create(:offer_code, products: [product])

      visit "#{product.long_url}/#{offer_code.code}"
      add_to_cart(product, offer_code:, quantity: 2)
      expect(page).to have_selector("[aria-label='Discount code']", text: offer_code.code)
      expect(page).to have_text("Discounts #{offer_code.code} US$-2", normalize_ws: true)
      expect(page).to have_text("Total US$18", normalize_ws: true)
      check_out(product)
      expect(Purchase.last.price_cents).to eq(1800)
    end
  end

  describe "offer code validity" do
    let(:seller) { create(:named_seller, display_offer_code_field: true) }
    let(:product) { create(:product, user: seller) }

    context "when the offer code is not yet valid" do
      let!(:offer_code) { create(:offer_code, user: seller, products: [product], valid_at: 1.year.from_now) }

      it "displays error messages" do
        visit "#{product.long_url}/#{offer_code.code}"
        expect(page).to have_selector("[role='status']", text: "Sorry, the discount code you wish to use is inactive.")
        add_to_cart(product)
        fill_in "Discount code", with: offer_code.code
        click_on "Apply"
        expect(page).to have_alert(text: "Sorry, the discount code you wish to use is inactive.")

        offer_code.update!(valid_at: nil)
        click_on "Apply"
        expect(page).to have_selector("[aria-label='Discount code']", text: offer_code.code)
        offer_code.update!(valid_at: 1.year.from_now)
        fill_checkout_form(product, is_free: true)
        click_on "Get"
        expect(page).to have_alert(text: "Sorry, the discount code you wish to use is inactive.")
      end
    end

    context "when the offer code is expired" do
      let!(:offer_code) { create(:offer_code, user: seller, products: [product], valid_at: 2.years.ago, expires_at: 1.year.ago) }

      it "displays error messages" do
        visit "#{product.long_url}/#{offer_code.code}"
        expect(page).to have_selector("[role='status']", text: "Sorry, the discount code you wish to use is inactive.")
        add_to_cart(product)
        fill_in "Discount code", with: offer_code.code
        click_on "Apply"
        expect(page).to have_alert(text: "Sorry, the discount code you wish to use is inactive.")

        offer_code.update!(expires_at: nil)
        click_on "Apply"
        expect(page).to have_selector("[aria-label='Discount code']", text: offer_code.code)
        offer_code.update!(valid_at: 1.year.ago)
        fill_checkout_form(product, is_free: true)
        click_on "Get"
        expect(page).to have_alert(text: "Sorry, the discount code you wish to use is inactive.")
      end
    end

    context "when the offer code's minimum quantity is not met" do
      let!(:offer_code) { create(:offer_code, user: seller, products: [product], minimum_quantity: 2) }

      it "displays error messages" do
        visit "#{product.long_url}/#{offer_code.code}"
        add_to_cart(product)
        fill_in "Discount code", with: offer_code.code
        click_on "Apply"
        expect(page).to have_alert(text: "Sorry, the discount code you wish to use has an unmet minimum quantity.")

        offer_code.update!(minimum_quantity: nil)
        click_on "Apply"
        expect(page).to have_selector("[aria-label='Discount code']", text: offer_code.code)
        offer_code.update!(minimum_quantity: 2)
        fill_checkout_form(product, is_free: true)
        click_on "Get"
        expect(page).to have_alert(text: "Sorry, the discount code you wish to use has an unmet minimum quantity.")
      end
    end
  end

  describe "offer code with duration" do
    context "when the product is a tiered membership" do
      let(:product) { create(:membership_product_with_preset_tiered_pricing) }
      let(:offer_code) { create(:offer_code, products: [product], duration_in_billing_cycles: 1) }

      it "displays the duration notice and the purchase succeeds" do
        visit "#{product.long_url}/#{offer_code.code}"
        expect(page).to have_selector("[role='status']", exact_text: "$1 off will be applied at checkout (Code SXSW) This discount will only apply to the first payment of your subscription.", normalize_ws: true)
        add_to_cart(product, option: "First Tier", offer_code:)
        check_out(product)

        purchase = Purchase.last
        expect(purchase.price_cents).to eq(200)
        expect(purchase.offer_code).to eq(offer_code)
        purchase_offer_code_discount = purchase.purchase_offer_code_discount
        expect(purchase_offer_code_discount.offer_code_amount).to eq(100)
        expect(purchase_offer_code_discount.duration_in_billing_cycles).to eq(1)
        expect(purchase_offer_code_discount.offer_code_is_percent).to eq(false)
      end
    end

    context "when the product is not a tiered membership" do
      let(:product) { create(:product, price_cents: 200) }
      let(:offer_code) { create(:offer_code, products: [product], duration_in_billing_cycles: 1) }

      it "doesn't display the duration notice and the purchase succeeds" do
        visit "#{product.long_url}/#{offer_code.code}"
        expect(page).to have_selector("[role='status']", exact_text: "$1 off will be applied at checkout (Code SXSW)", normalize_ws: true)
        add_to_cart(product, offer_code:)
        check_out(product)

        purchase = Purchase.last
        expect(purchase.offer_code).to eq(offer_code)
        expect(purchase.purchase_offer_code_discount.duration_in_billing_cycles).to eq(nil)
      end
    end
  end

  describe "offer code with minimum amount" do
    let(:seller) { create(:named_seller) }
    let(:product1) { create(:product, name: "Product 1", user: seller) }
    let(:product2) { create(:product, name: "Product 2", user: seller) }
    let(:product3) { create(:product, name: "Product 3", user: seller) }
    let(:offer_code) { create(:offer_code, user: seller, products: [product1, product3], minimum_amount_cents: 200) }

    context "when the cart has an insufficient amount" do
      it "doesn't apply the discount" do
        visit "#{product1.long_url}/#{offer_code.code}"
        expect(page).to have_selector("[role='status']", text: "$1 off will be applied at checkout (Code SXSW) This discount will apply when you spend $2 or more in selected products.", normalize_ws: true)
        add_to_cart(product1, offer_code:)
        expect(page).to have_selector("[aria-label='Discount code']", text: offer_code.code)
        expect(page).to have_text("Total US$1", normalize_ws: true)
        check_out(product1)

        purchase = Purchase.last
        expect(purchase.price_cents).to eq(100)
        expect(purchase.offer_code).to eq(nil)
      end
    end

    context "when the cart has a sufficient amount" do
      it "applies the discount" do
        visit "#{product1.long_url}/#{offer_code.code}"
        expect(page).to have_selector("[role='status']", text: "$1 off will be applied at checkout (Code SXSW) This discount will apply when you spend $2 or more in selected products.", normalize_ws: true)
        add_to_cart(product1, offer_code:)
        expect(page).to have_selector("[aria-label='Discount code']", text: offer_code.code)
        expect(page).to have_text("Total US$1", normalize_ws: true)

        visit product2.long_url
        add_to_cart(product2)
        expect(page).to have_selector("[aria-label='Discount code']", text: offer_code.code)
        expect(page).to have_text("Total US$2", normalize_ws: true)

        visit "#{product3.long_url}/#{offer_code.code}"
        expect(page).to have_selector("[role='status']", text: "$1 off will be applied at checkout (Code SXSW) This discount will apply when you spend $2 or more in selected products.", normalize_ws: true)
        add_to_cart(product3, offer_code:)
        expect(page).to have_selector("[aria-label='Discount code']", text: offer_code.code)
        expect(page).to have_text("Total US$1", normalize_ws: true)

        check_out(product3)

        purchase1 = Purchase.last
        expect(purchase1.price_cents).to eq(0)
        expect(purchase1.offer_code).to eq(offer_code)
        purchase2 = Purchase.second_to_last
        expect(purchase2.price_cents).to eq(100)
        expect(purchase2.offer_code).to eq(nil)
        purchase3 = Purchase.third_to_last
        expect(purchase3.price_cents).to eq(0)
        expect(purchase3.offer_code).to eq(offer_code)
      end

      context "when a product in the cart has a quantity greater than 1" do
        before { product1.update!(quantity_enabled: true) }

        it "applies the discount" do
          visit "#{product1.long_url}/#{offer_code.code}"
          add_to_cart(product1, offer_code:)
          expect(page).to have_selector("[aria-label='Discount code']", text: offer_code.code)
          expect(page).to have_text("Total US$1", normalize_ws: true)

          visit "#{product1.long_url}/#{offer_code.code}"
          add_to_cart(product1, offer_code:, quantity: 2)
          expect(page).to have_selector("[aria-label='Discount code']", text: offer_code.code)
          expect(page).to have_text("Total US$0", normalize_ws: true)
          check_out(product1, is_free: true)

          purchase = Purchase.last
          expect(purchase.price_cents).to eq(0)
          expect(purchase.quantity).to eq(2)
          expect(purchase.offer_code).to eq(offer_code)
        end
      end
    end

    context "when the offer code is universal" do
      before do
        offer_code.update!(universal: true, products: [])
      end

      context "when the cart has an insufficient amount" do
        it "doesn't apply the discount" do
          visit "#{product1.long_url}/#{offer_code.code}"
          expect(page).to have_selector("[role='status']", text: "$1 off will be applied at checkout (Code SXSW) This discount will apply when you spend $2 or more in Seller's products.", normalize_ws: true)
          add_to_cart(product1, offer_code:)
          expect(page).to have_selector("[aria-label='Discount code']", text: offer_code.code)
          expect(page).to have_text("Total US$1", normalize_ws: true)
          check_out(product1)

          purchase = Purchase.last
          expect(purchase.price_cents).to eq(100)
          expect(purchase.offer_code).to eq(nil)
        end
      end

      context "when the cart has a sufficient amount" do
        it "applies the discount" do
          visit "#{product1.long_url}/#{offer_code.code}"
          expect(page).to have_selector("[role='status']", text: "$1 off will be applied at checkout (Code SXSW) This discount will apply when you spend $2 or more in Seller's products.", normalize_ws: true)
          add_to_cart(product1, offer_code:)
          expect(page).to have_selector("[aria-label='Discount code']", text: offer_code.code)
          expect(page).to have_text("Total US$1", normalize_ws: true)

          visit "#{product2.long_url}/#{offer_code.code}"
          expect(page).to have_selector("[role='status']", text: "$1 off will be applied at checkout (Code SXSW) This discount will apply when you spend $2 or more in Seller's products.", normalize_ws: true)
          add_to_cart(product2, offer_code:)
          expect(page).to have_selector("[aria-label='Discount code']", text: offer_code.code)
          expect(page).to have_text("Total US$0", normalize_ws: true)

          visit "#{product3.long_url}/#{offer_code.code}"
          expect(page).to have_selector("[role='status']", text: "$1 off will be applied at checkout (Code SXSW) This discount will apply when you spend $2 or more in Seller's products.", normalize_ws: true)
          add_to_cart(product3, offer_code:)
          expect(page).to have_selector("[aria-label='Discount code']", text: offer_code.code)
          expect(page).to have_text("Total US$0", normalize_ws: true)

          check_out(product3, is_free: true)

          purchase1 = Purchase.last
          expect(purchase1.price_cents).to eq(0)
          expect(purchase1.offer_code).to eq(offer_code)
          purchase2 = Purchase.second_to_last
          expect(purchase2.price_cents).to eq(0)
          expect(purchase2.offer_code).to eq(offer_code)
          purchase3 = Purchase.third_to_last
          expect(purchase3.price_cents).to eq(0)
          expect(purchase3.offer_code).to eq(offer_code)
        end
      end
    end

    context "when the offer code only applies to one product" do
      before do
        offer_code.update!(products: [product1])
      end

      it "displays the correct notice" do
        visit "#{product1.long_url}/#{offer_code.code}"
        expect(page).to have_selector("[role='status']", text: "$1 off will be applied at checkout (Code SXSW) This discount will apply when you spend $2 or more.", normalize_ws: true)
      end
    end
  end
end
