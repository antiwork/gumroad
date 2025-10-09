# frozen_string_literal: true

require("spec_helper")

describe("Product checkout with tipping", type: :system, js: true) do
  let(:seller) { create(:named_seller, :eligible_for_service_products, tipping_enabled: true) }
  let(:product1) { create(:product, name: "Product 1", user: seller, price_cents: 1000, quantity_enabled: true) }
  let(:product2) { create(:product, name: "Product 2", user: seller, price_cents: 2000) }

  context "when the products have tipping enabled" do
    it "allows the buyer to tip a percentage" do
      visit product1.long_url
      fill_in "Quantity", with: 2
      add_to_cart(product1, quantity: 2)
      visit product2.long_url
      add_to_cart(product2)
      fill_checkout_form(product2)

      expect(page).to have_radio_button("0%", checked: true)

      choose "10%"

      expect(page).to have_text("Subtotal US$40", normalize_ws: true)
      expect(page).to have_text("Tip US$4", normalize_ws: true)
      expect(page).to have_text("Total US$44", normalize_ws: true)
      click_on "Pay"

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase1 = Purchase.last
      expect(purchase1).to be_successful
      expect(purchase1.link).to eq(product1)
      expect(purchase1.price_cents).to eq(2200)
      expect(purchase1.tip.value_cents).to eq(200)

      purchase2 = Purchase.second_to_last
      expect(purchase2).to be_successful
      expect(purchase2.link).to eq(product2)
      expect(purchase2.price_cents).to eq(2200)
      expect(purchase2.tip.value_cents).to eq(200)
    end

    it "allows the buyer to tip a fixed amount" do
      visit product1.long_url
      add_to_cart(product1)
      visit product2.long_url
      add_to_cart(product2)
      fill_checkout_form(product2)

      expect(page).to have_radio_button("0%", checked: true)

      choose "Other"
      fill_in "Tip", with: 20

      expect(page).to have_text("Subtotal US$30", normalize_ws: true)
      expect(page).to have_text("Tip US$20", normalize_ws: true)
      expect(page).to have_text("Total US$50", normalize_ws: true)
      click_on "Pay"

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase1 = Purchase.last
      expect(purchase1).to be_successful
      expect(purchase1.link).to eq(product1)
      expect(purchase1.price_cents).to eq(1667)
      expect(purchase1.tip.value_cents).to eq(667)

      purchase2 = Purchase.second_to_last
      expect(purchase2).to be_successful
      expect(purchase2.link).to eq(product2)
      expect(purchase2.price_cents).to eq(3333)
      expect(purchase2.tip.value_cents).to eq(1333)
    end

    context "when only coffee products are in the cart" do
      let(:coffee_product) { create(:product, user: seller, price_cents: 1000, native_type: Link::NATIVE_TYPE_COFFEE) }
      let(:product) { create(:product, user: seller, price_cents: 1500) }

      it "doesn't allow tipping" do
        visit coffee_product.long_url
        click_on "Donate"
        fill_checkout_form(coffee_product)

        expect(page).not_to have_text("Add a tip")
        expect(page).not_to have_radio_button("0%")
        expect(page).not_to have_radio_button("10%")
        expect(page).not_to have_radio_button("20%")
        expect(page).not_to have_radio_button("Other")

        expect(page).to have_text("Subtotal US$10", normalize_ws: true)
        expect(page).to have_text("Total US$10", normalize_ws: true)

        visit product.long_url
        add_to_cart(product)
        fill_checkout_form(product)

        expect(page).to have_text("Add a tip")
        expect(page).to have_radio_button("0%", checked: true)
        expect(page).to have_radio_button("10%")
        expect(page).to have_radio_button("20%")
        expect(page).to have_radio_button("Other")

        choose "10%"

        expect(page).to have_text("Subtotal US$25", normalize_ws: true)
        expect(page).to have_text("Tip US$2.50", normalize_ws: true)
        expect(page).to have_text("Total US$27.50", normalize_ws: true)
        click_on "Pay"

        expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

        purchase1 = Purchase.last
        expect(purchase1).to be_successful
        expect(purchase1.link).to eq(coffee_product)
        expect(purchase1.price_cents).to eq(1100)
        expect(purchase1.tip.value_cents).to eq(100)

        purchase2 = Purchase.second_to_last
        expect(purchase2).to be_successful
        expect(purchase2.link).to eq(product)
        expect(purchase2.price_cents).to eq(1650)
        expect(purchase2.tip.value_cents).to eq(150)
      end
    end
  end

  context "when the cart is free," do
    let(:seller2) { create(:user, :eligible_for_service_products, tipping_enabled: true, name: "Seller 2", username: "seller2", email: "seller2@example.com", payment_address: "seller2@example.com") }
    let(:free_product1) { create(:product, name: "Free Product 1", user: seller, price_cents: 0) }
    let(:free_product2) { create(:product, name: "Free Product 2", user: seller, price_cents: 0) }
    let(:free_product3) { create(:product, name: "Free Product 3", user: seller2, price_cents: 0) }

    it "only allows the buyer to tip a fixed amount" do
      visit free_product2.long_url
      add_to_cart(free_product2, pwyw_price: 0)
      visit free_product1.long_url
      add_to_cart(free_product1, pwyw_price: 0)

      expect(page).not_to have_radio_button("0%")
      expect(page).not_to have_radio_button("10%")
      expect(page).not_to have_radio_button("20%")
      expect(page).not_to have_radio_button("Other")

      fill_in "Tip", with: 5

      expect(page).not_to have_radio_button("0%")
      expect(page).not_to have_radio_button("10%")
      expect(page).not_to have_radio_button("20%")
      expect(page).not_to have_radio_button("Other")

      fill_checkout_form(free_product2)

      expect(page).to have_text("Subtotal US$0", normalize_ws: true)
      expect(page).to have_text("Tip US$5", normalize_ws: true)
      expect(page).to have_text("Total US$5", normalize_ws: true)
      click_on "Pay"

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase_free_product2 = Purchase.last
      expect(purchase_free_product2).to be_successful
      expect(purchase_free_product2.link).to eq(free_product2)
      expect(purchase_free_product2.price_cents).to eq(0)
      expect(purchase_free_product2.tip).to be_nil

      purchase_free_product1 = Purchase.second_to_last
      expect(purchase_free_product1).to be_successful
      expect(purchase_free_product1.link).to eq(free_product1)
      expect(purchase_free_product1.price_cents).to eq(500)
      expect(purchase_free_product1.tip.value_cents).to eq(500)
    end

    context "for single creator" do
      it "applies full tip to first product when tip meets minimum" do
        visit free_product2.long_url
        add_to_cart(free_product2, pwyw_price: 0)
        visit free_product1.long_url
        add_to_cart(free_product1, pwyw_price: 0)

        fill_in "Tip", with: 0.99
        fill_checkout_form(free_product1)
        expect(page).to have_text("Total US$0.99", normalize_ws: true)
        click_on "Pay"

        expect(page).to have_alert(text: "Your purchase was successful!")

        purchase1 = Purchase.second_to_last
        purchase2 = Purchase.last

        expect(purchase1.tip.value_cents).to eq(99)
        expect(purchase1.price_cents).to eq(99)

        expect(purchase2.tip).to be_nil
        expect(purchase2.price_cents).to eq(0)
      end

      it "shows backend validation error when tip below minimum" do
        visit free_product1.long_url
        add_to_cart(free_product1, pwyw_price: 0)

        fill_in "Tip", with: 0.5
        fill_checkout_form(free_product1)
        expect(page).to have_text("Total US$0.5", normalize_ws: true)
        click_on "Pay"

        expect(page).to have_text("The amount must be at least $0.99.")
      end
    end

    context "for multiple creators" do
      it "distributes tip per creator to first product from each when tip meets minimum" do
        visit free_product3.long_url
        add_to_cart(free_product3, pwyw_price: 0)
        visit free_product1.long_url
        add_to_cart(free_product1, pwyw_price: 0)

        fill_in "Tip", with: 1.98
        fill_checkout_form(free_product1)
        expect(page).to have_text("Total US$1.98", normalize_ws: true)
        click_on "Pay"

        expect(page).to have_alert(text: "Your purchase was successful!")

        purchase1 = Purchase.second_to_last
        purchase3 = Purchase.last

        expect(purchase1.tip.value_cents).to eq(99)
        expect(purchase1.price_cents).to eq(99)
        expect(purchase3.tip.value_cents).to eq(99)
        expect(purchase3.price_cents).to eq(99)
      end

      it "shows backend validation error with per-creator minimum when tip below minimum" do
        visit free_product3.long_url
        add_to_cart(free_product3, pwyw_price: 0)
        visit free_product1.long_url
        add_to_cart(free_product1, pwyw_price: 0)

        fill_in "Tip", with: 1.5
        fill_checkout_form(free_product1)
        expect(page).to have_text("Total US$1.5", normalize_ws: true)
        click_on "Pay"

        expect(page).to have_text("The amount must be at least $0.99.", count: 2)
      end
    end
  end

  context "when there's a membership in the cart" do
    let(:membership_product) { create(:membership_product) }

    it "doesn't allow tipping" do
      visit membership_product.long_url
      click_on "Subscribe"
      fill_checkout_form(membership_product)
      wait_for_ajax

      expect(page).not_to have_text("Add a tip")

      click_on "Pay"

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase = Purchase.last
      expect(purchase).to be_successful
      expect(purchase.link).to eq(membership_product)
      expect(purchase.tip).to be_nil
    end
  end

  context "when there's a legacy subscription in the cart" do
    let(:product) { create(:product, :is_subscription, user: seller) }

    it "doesn't allow tipping" do
      visit product.long_url
      click_on "Subscribe"
      fill_checkout_form(product)
      wait_for_ajax

      expect(page).not_to have_text("Add a tip")

      click_on "Pay"

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase = Purchase.last
      expect(purchase).to be_successful
      expect(purchase.link).to eq(product)
      expect(purchase.tip).to be_nil
    end
  end

  context "when custom tipping options are set" do
    before do
      TipOptionsService.set_tip_options([5, 15, 25])
      TipOptionsService.set_default_tip_option(15)
    end

    it "allows selecting a custom tip option" do
      visit product1.long_url

      add_to_cart(product1)

      expect(page).to have_radio_button("5%", checked: false)
      expect(page).to have_radio_button("15%", checked: true)
      expect(page).to have_radio_button("25%", checked: false)
      expect(page).to have_radio_button("Other", checked: false)
    end
  end

  context "when there's a discount code in the cart" do
    let(:offer_code) { create(:percentage_offer_code, user: product1.user, products: [product1]) }
    it "tips on the post-discount price" do
      visit "#{product1.long_url}/#{offer_code.code}"
      add_to_cart(product1, offer_code:)
      visit product2.long_url
      add_to_cart(product2)
      fill_checkout_form(product2)
      expect(page).to have_text("Subtotal US$30", normalize_ws: true)
      expect(page).to have_text("Discounts #{offer_code.code} US$-5", normalize_ws: true)
      expect(page).to have_text("Total US$25", normalize_ws: true)

      choose "20%"
      wait_for_ajax

      expect(page).to have_text("Subtotal US$30", normalize_ws: true)
      expect(page).to have_text("Discounts #{offer_code.code} US$-5", normalize_ws: true)
      expect(page).to have_text("Tip US$5", normalize_ws: true)
      expect(page).to have_text("Total US$30", normalize_ws: true)

      click_on "Pay"

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase1 = Purchase.last
      expect(purchase1).to be_successful
      expect(purchase1.link).to eq(product1)
      expect(purchase1.price_cents).to eq(600)
      expect(purchase1.tip.value_cents).to eq(100)

      purchase2 = Purchase.second_to_last
      expect(purchase2).to be_successful
      expect(purchase2.link).to eq(product2)
      expect(purchase2.price_cents).to eq(2400)
      expect(purchase2.tip.value_cents).to eq(400)
    end
  end

  context "when the product is priced in non-USD currency" do
    let(:product) { create(:product, user: seller, price_cents: 500000, price_currency_type: Currency::KRW) }

    it "computes the correct tip" do
      visit product.long_url
      add_to_cart(product)
      fill_checkout_form(product)

      choose "20%"
      wait_for_ajax

      expect(page).to have_text("Subtotal US$4.34", normalize_ws: true)
      expect(page).to have_text("Tip US$0.87", normalize_ws: true)
      expect(page).to have_text("Total US$5.21", normalize_ws: true)

      click_on "Pay"
      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase = Purchase.last
      expect(purchase).to be_successful
      expect(purchase.displayed_price_currency_type).to be(:krw)
      expect(purchase.displayed_price_cents).to eq(600000)
      expect(purchase.price_cents).to eq(521)
      expect(purchase.tip.value_cents).to eq(100000)
      expect(purchase.tip.value_usd_cents).to eq(87)
    end
  end

  context "when there is no tip" do
    it "doesn't create a tip record" do
      visit product1.long_url
      add_to_cart(product1)
      fill_checkout_form(product1)
      click_on "Pay"

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase = Purchase.last
      expect(purchase).to be_successful
      expect(purchase.tip).to be_nil
    end
  end

  context "when the product is a commission" do
    let(:commission_product) { create(:commission_product) }

    before { commission_product.user.update!(tipping_enabled: true) }

    it "charges the correct amount for the deposit purchase" do
      visit commission_product.long_url
      add_to_cart(commission_product)
      visit product2.long_url
      add_to_cart(product2)
      fill_checkout_form(commission_product)

      expect(page).to have_text("Subtotal US$22", normalize_ws: true)
      expect(page).to have_text("Total US$22", normalize_ws: true)
      expect(page).to have_text("Payment today US$21", normalize_ws: true)
      expect(page).to have_text("Payment after completion US$1", normalize_ws: true)

      choose "20%"

      expect(page).to have_text("Subtotal US$22", normalize_ws: true)
      expect(page).to have_text("Tip US$4.40", normalize_ws: true)
      expect(page).to have_text("Total US$26.40", normalize_ws: true)
      expect(page).to have_text("Payment today US$25.20", normalize_ws: true)
      expect(page).to have_text("Payment after completion US$1.20", normalize_ws: true)

      click_on "Pay"

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase = Purchase.last
      expect(purchase).to be_successful
      expect(purchase.price_cents).to eq(120)
      expect(purchase.tip.value_cents).to eq(20)
    end
  end
end
