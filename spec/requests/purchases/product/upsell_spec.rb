# frozen_string_literal: true

require("spec_helper")

describe("Product checkout with upsells", type: :system, js: true) do
  let(:seller) { create(:named_seller) }

  let(:upsell_product) { create(:product_with_digital_versions, name: "Upsell product", user: seller) }
  let!(:upsell) { create(:upsell, text: "Upsell", description: "Check out this awesome upsell at https://upsell.com!", seller:, product: upsell_product) }
  let!(:upsell_variant) { create(:upsell_variant, upsell:, selected_variant: upsell_product.alive_variants.first, offered_variant: upsell_product.alive_variants.second) }

  let(:selected_product) { create(:product, name: "Product", user: seller) }
  let(:product) { create(:product_with_digital_versions, name: "Offered product", user: seller) }
  let!(:cross_sell) { create(:upsell, text: "Cross-sell", description: "Check out this awesome cross-sell at https://cross-sell.com!", seller:, product:, variant: product.alive_variants.first, selected_products: [selected_product], offer_code: create(:offer_code, user: seller, products: [product]), cross_sell: true) }

  context "when the product has an upsell" do
    it "allows the buyer to accept the upsell at checkout" do
      visit upsell_product.long_url
      add_to_cart(upsell_product, option: "Untitled 1")
      fill_checkout_form(upsell_product)

      click_on "Pay"

      within_modal "Upsell" do
        expect(page).to have_text("Check out this awesome upsell at https://upsell.com!")
        link = find_link("https://upsell.com", href: "https://upsell.com", target: "_blank")
        expect(link["rel"]).to eq("noopener")
        expect(page).to have_radio_button("Untitled 2")
        click_on "Upgrade"
      end

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")
      expect(page).to_not have_text("Upsell product - Untitled 1")
      expect(page).to have_text("Upsell product - Untitled 2")

      purchase = Purchase.last
      expect(purchase.upsell_purchase.upsell).to eq(upsell)
      expect(purchase.upsell_purchase.selected_product).to eq(upsell_product)
      expect(purchase.upsell_purchase.upsell_variant).to eq(upsell_variant)
      expect(purchase.variant_attributes.first).to eq(upsell_product.alive_variants.second)
    end

    it "allows the buyer to decline the upsell at checkout" do
      visit upsell_product.long_url
      add_to_cart(upsell_product, option: "Untitled 1")
      fill_checkout_form(upsell_product)

      click_on "Pay"

      within_modal "Upsell" do
        expect(page).to have_text("Check out this awesome upsell at https://upsell.com!")
        expect(page).to have_radio_button("Untitled 2")
        click_on "Don't upgrade"
      end

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")
      expect(page).to have_text("Upsell product - Untitled 1")
      expect(page).to_not have_text("Upsell product - Untitled 2")

      purchase = Purchase.last
      expect(purchase.upsell_purchase).to be_nil
      expect(purchase.variant_attributes.first).to eq(upsell_product.alive_variants.first)
    end

    context "when the upsell is paused" do
      before { upsell.update!(paused: true) }

      it "doesn't offer the upsell at checkout" do
        visit upsell_product.long_url
        add_to_cart(upsell_product, option: "Untitled 1")
        check_out(upsell_product)
      end
    end
  end

  context "when the product has a cross-sell" do
    it "allows the buyer to accept the cross-sell at checkout" do
      visit selected_product.long_url
      add_to_cart(selected_product)
      fill_checkout_form(selected_product)

      click_on "Pay"

      within_modal "Cross-sell" do
        expect(page).to have_text("Check out this awesome cross-sell at https://cross-sell.com!")
        link = find_link("https://cross-sell.com", href: "https://cross-sell.com", target: "_blank")
        expect(link["rel"]).to eq("noopener")
        expect(page).to have_selector("[itemprop='price']", text: "$1 $0", normalize_ws: true)
        expect(page).to have_section("Offered product - Untitled 1")
        expect(page).to have_link(href: product.long_url)
        click_on "Add to cart"
      end

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")
      expect(page).to have_section("Product")
      expect(page).to have_section("Offered product - Untitled 1")

      purchase = Purchase.last
      expect(purchase.link).to eq(product)
      expect(purchase.variant_attributes.first).to eq(product.alive_variants.first)
      expect(purchase.upsell_purchase.upsell).to eq(cross_sell)
      expect(purchase.upsell_purchase.selected_product).to eq(selected_product)
      expect(purchase.offer_code).to eq(cross_sell.offer_code)
    end

    context "when the buyer tips" do
      before do
        seller.update!(tipping_enabled: true)
        product.update!(price_cents: 500)
      end

      it "allows the buyer to accept the cross-sell at checkout" do
        visit selected_product.long_url
        add_to_cart(selected_product)
        fill_checkout_form(selected_product)
        choose "20%"

        click_on "Pay"

        within_modal "Cross-sell" do
          click_on "Add to cart"
        end
        expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

        cross_sell_purchase = Purchase.last
        expect(cross_sell_purchase.link).to eq(product)
        expect(cross_sell_purchase.variant_attributes.first).to eq(product.alive_variants.first)
        expect(cross_sell_purchase.upsell_purchase.upsell).to eq(cross_sell)
        expect(cross_sell_purchase.upsell_purchase.selected_product).to eq(selected_product)
        expect(cross_sell_purchase.offer_code).to eq(cross_sell.offer_code)
        expect(cross_sell_purchase.price_cents).to eq(480)
        expect(cross_sell_purchase.tip.value_cents).to eq(80)


        purchase = Purchase.second_to_last
        expect(purchase.link).to eq(selected_product)
        expect(purchase.price_cents).to eq(120)
        expect(purchase.tip.value_cents).to eq(20)
      end
    end

    it "allows the buyer to decline the cross-sell at checkout" do
      visit selected_product.long_url
      add_to_cart(selected_product)
      fill_checkout_form(selected_product)

      click_on "Pay"

      within_modal "Cross-sell" do
        expect(page).to have_text("Check out this awesome cross-sell at https://cross-sell.com!")
        expect(page).to have_selector("[itemprop='price']", text: "$1 $0", normalize_ws: true)
        expect(page).to have_section("Offered product - Untitled 1")
        expect(page).to have_link(href: product.long_url)
        click_on "Continue without adding"
      end

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")
      expect(page).to have_section("Product")
      expect(page).to_not have_section("Offered product - Untitled 1")

      purchase = Purchase.last
      expect(purchase.upsell_purchase).to be_nil
      expect(purchase.variant_attributes.first).to eq(selected_product.alive_variants.first)
    end

    context "when the cross-sell is paused" do
      before { cross_sell.update!(paused: true) }

      it "doesn't offer the cross-sell at checkout" do
        visit selected_product.long_url
        add_to_cart(selected_product)
        check_out(selected_product)
      end
    end

    context "when the buyer has a better discount code" do
      let!(:cross_sell) { nil }  # Override global cross_sell to avoid conflicts
      let!(:additive_cross_sell) { create(:upsell, text: "Cross-sell", description: "Check out this awesome cross-sell!", seller:, product:, variant: product.alive_variants.first, selected_products: [selected_product], cross_sell: true, replace_selected_products: false) }
      let(:better_discount_code) { create(:offer_code, code: "betterdiscount", user: seller, universal: true, amount_cents: 100) }

      before do
        product.update!(price_cents: 400)
        selected_product.update!(price_cents: 200)
      end

      it "applies applicable discount codes to non-replacement cross-sells" do
        visit "#{selected_product.long_url}/#{better_discount_code.code}"
        add_to_cart(selected_product, offer_code: better_discount_code)

        fill_checkout_form(selected_product)
        click_on "Pay"

        within_modal "Cross-sell" do
          expect(page).to have_text("Check out this awesome cross-sell!")
          expect(page).to have_section("Offered product")
          # The modal shows the original discount applied to the cross-sell
          expect(page).to have_selector("[itemprop='price']", text: "$4 $3")
          click_on "Add to cart"
        end

        expect(page).to have_section("Offered product")
        expect(page).to have_section("Product")
        # Cart retains the original discount code and applies it to both products
        expect(page).to have_selector("[aria-label='Discount code']", text: better_discount_code.code)
        # $1 off each product
        expect(page).to have_text("US$-2")

        expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

        expect(page).to have_section("Offered product")
        expect(page).to have_section("Product")

        selected_purchase = selected_product.sales.last
        offered_purchase = product.sales.last

        expect(selected_purchase.price_cents).to eq(100) # $200 - $100 discount
        expect(selected_purchase.offer_code).to eq(better_discount_code)
        expect(selected_purchase.upsell_purchase).to be_nil

        expect(offered_purchase.price_cents).to eq(300) # $400 - $100 discount
        expect(offered_purchase.offer_code).to eq(better_discount_code)
        expect(offered_purchase.upsell_purchase.selected_product).to eq(selected_product)
        expect(offered_purchase.upsell_purchase.upsell).to eq(additive_cross_sell)
      end
    end
  end

  context "when the product has a universal cross-sell" do
    let(:unassociated_product) { create(:product, user: seller, name: "Unassociated product") }
    let!(:universal_cross_sell) { create(:upsell, text: "Cross-sell", description: "Check out this awesome cross-sell!", seller:, product:, variant: product.alive_variants.first, selected_products: [], cross_sell: true, universal: true) }

    it "allows the buyer to accept the cross-sell at checkout" do
      visit unassociated_product.long_url
      add_to_cart(unassociated_product)
      fill_checkout_form(unassociated_product)

      click_on "Pay"

      within_modal "Cross-sell" do
        expect(page).to have_text("Check out this awesome cross-sell!")
        expect(page).to have_selector("[itemprop='price']", text: "$1", normalize_ws: true)
        expect(page).to have_section("Offered product - Untitled 1")
        expect(page).to have_link(href: product.long_url)
        click_on "Add to cart"
      end

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")
      expect(page).to have_section("Unassociated product")
      expect(page).to have_section("Offered product - Untitled 1")

      purchase = Purchase.last
      expect(purchase.link).to eq(product)
      expect(purchase.variant_attributes.first).to eq(product.alive_variants.first)
      expect(purchase.upsell_purchase.upsell).to eq(universal_cross_sell)
      expect(purchase.upsell_purchase.selected_product).to eq(unassociated_product)
      expect(purchase.offer_code).to eq(nil)
    end
  end

  context "when the product has a replacement cross-sell" do
    let(:product) { create(:product, user: seller, name: "Offered product", price_cents: 400) }
    let(:selected_product1) { create(:product, user: seller, name: "Selected product 1", price_cents: 200) }
    let(:selected_product2) { create(:product, user: seller, name: "Selected product 2", price_cents: 200) }
    let!(:replacement_cross_sell) { create(:upsell, text: "Replacement cross-sell", seller:, product:, variant: product.alive_variants.first, selected_products: [selected_product1, selected_product2], offer_code: build(:offer_code, user: seller, products: [product], amount_cents: 50), cross_sell: true, replace_selected_products: true) }

    it "removes the selected products when the buyer accepts the cross-sell" do
      visit selected_product1.long_url
      add_to_cart(selected_product1)

      visit selected_product2.long_url
      add_to_cart(selected_product2)

      fill_checkout_form(selected_product2)
      click_on "Pay"

      within_modal "Replacement cross-sell" do
        expect(page).to have_text("This offer will only last for a few weeks.")
        expect(page).to have_section("Offered product")
        expect(page).to have_selector("[itemprop='price']", text: "$4 $3.50")
        click_on "Upgrade"
      end

      expect(page).to have_section("Offered product")
      expect(page).to_not have_section("Selected product 1")
      expect(page).to_not have_section("Selected product 2")
      expect(page).to_not have_selector("[aria-label='Discount code']")
      expect(page).to have_text("US$-0.50")

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      expect(page).to have_section("Offered product")
      expect(page).to_not have_section("Selected product 1")
      expect(page).to_not have_section("Selected product 2")

      purchase = Purchase.last
      expect(purchase.link).to eq(product)
      expect(purchase.price_cents).to eq(350)
      expect(purchase.offer_code).to eq(replacement_cross_sell.offer_code)
      expect(purchase.upsell_purchase.selected_product).to eq(selected_product2)
      expect(purchase.upsell_purchase.upsell).to eq(replacement_cross_sell)
    end

    context "when the buyer has a better discount code" do
      let(:better_discount_code) { create(:offer_code, code: "betterdiscount", user: seller, universal: true, amount_cents: 100) }

      it "retains the original discount code if it's better than the replacement cross-sell discount" do
        visit "#{selected_product1.long_url}/#{better_discount_code.code}"
        add_to_cart(selected_product1, offer_code: better_discount_code)

        fill_checkout_form(selected_product1)
        click_on "Pay"

        within_modal "Replacement cross-sell" do
          expect(page).to have_text("This offer will only last for a few weeks.")
          expect(page).to have_section("Offered product")
          # The modal shows original discount that is better than the replacement
          # cross-sell discount.
          expect(page).to have_selector("[itemprop='price']", text: "$4 $3")
          click_on "Upgrade"
        end

        expect(page).to have_section("Offered product")
        expect(page).to_not have_section("Selected product 1")
        # Cart retains the original discount code after accepting the replacement
        # cross-sell.
        expect(page).to have_selector("[aria-label='Discount code']", text: better_discount_code.code)
        expect(page).to have_text("US$-1")

        expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

        expect(page).to have_section("Offered product")
        expect(page).to_not have_section("Selected product 1")

        purchase = Purchase.last
        expect(purchase.link).to eq(product)
        expect(purchase.price_cents).to eq(300)
        expect(purchase.offer_code).to eq(better_discount_code)
        expect(purchase.upsell_purchase.selected_product).to eq(selected_product1)
        expect(purchase.upsell_purchase.upsell).to eq(replacement_cross_sell)
      end
    end

    context "selected product is free and offered product is paid" do
      before do
        selected_product1.update!(price_cents: 0)
        # Indian IP address so that the ZIP code field doesn't get the error instead of the card input
        allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("182.23.143.254")
      end

      it "marks the card input as invalid and doesn't show an error" do
        visit selected_product1.long_url
        add_to_cart(selected_product1, pwyw_price: 0)
        fill_checkout_form(selected_product1, is_free: true)
        click_on "Get"
        click_on "Upgrade"

        expect(page).to_not have_alert
        expect(page).to have_selector("[aria-label='Card information'][aria-invalid='true']")
      end
    end
  end

  context "when there are multiple upsells" do
    it "allows the buyer to accept each upsell at checkout" do
      visit upsell_product.long_url
      add_to_cart(upsell_product, option: "Untitled 1")

      visit selected_product.long_url
      add_to_cart(selected_product)

      fill_checkout_form(selected_product)

      click_on "Pay"

      within_modal "Cross-sell" do
        expect(page).to have_text("Check out this awesome cross-sell at https://cross-sell.com!")
        expect(page).to have_section("Offered product - Untitled 1")
        expect(page).to have_selector("[itemprop='price']", text: "$1 $0")
        expect(page).to have_link(href: product.long_url)
        click_on "Add to cart"
      end

      within_modal "Upsell" do
        expect(page).to have_text("Check out this awesome upsell at https://upsell.com!")
        expect(page).to have_radio_button("Untitled 2", text: "$1")
        click_on "Upgrade"
      end

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com")

      expect(page).to have_section("Product")
      expect(page).to have_section("Offered product - Untitled 1")
      expect(page).to have_section("Upsell product - Untitled 2")

      purchase1 = Purchase.second_to_last
      expect(purchase1.link).to eq(product)
      expect(purchase1.variant_attributes.first).to eq(product.alive_variants.first)
      expect(purchase1.upsell_purchase.upsell).to eq(cross_sell)
      expect(purchase1.upsell_purchase.selected_product).to eq(selected_product)
      expect(purchase1.offer_code).to eq(cross_sell.offer_code)
      purchase2 = Purchase.last
      expect(purchase2.upsell_purchase.upsell).to eq(upsell)
      expect(purchase2.upsell_purchase.selected_product).to eq(upsell_product)
      expect(purchase2.upsell_purchase.upsell_variant).to eq(upsell_variant)
      expect(purchase2.variant_attributes.first).to eq(upsell_product.alive_variants.second)
    end

    it "allows the buyer to decline each upsell at checkout" do
      visit upsell_product.long_url
      add_to_cart(upsell_product, option: "Untitled 1")

      visit selected_product.long_url
      add_to_cart(selected_product)

      fill_checkout_form(selected_product)

      click_on "Pay"

      within_modal "Cross-sell" do
        expect(page).to have_text("Check out this awesome cross-sell at https://cross-sell.com!")
        expect(page).to have_section("Offered product - Untitled 1")
        expect(page).to have_selector("[itemprop='price']", text: "$1 $0")
        expect(page).to have_link(href: product.long_url)
        click_on "Continue without adding"
      end

      within_modal "Upsell" do
        expect(page).to have_text("Check out this awesome upsell at https://upsell.com!")
        expect(page).to have_radio_button("Untitled 2", text: "$1")
        click_on "Don't upgrade"
      end

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com")

      purchase1 = Purchase.last
      expect(purchase1.upsell_purchase).to be_nil
      expect(purchase1.variant_attributes.first).to eq(upsell_product.alive_variants.first)
      purchase2 = Purchase.second_to_last
      expect(purchase2.upsell_purchase).to be_nil
      expect(purchase2.variant_attributes.first).to be_nil
    end
  end

  context "when the cross-sold products has additional required fields" do
    let!(:cross_sell) { create(:upsell, seller:, product: create(:product, :with_custom_fields, user: seller), selected_products: [selected_product], cross_sell: true) }

    it "validates those fields" do
      visit selected_product.long_url
      add_to_cart(selected_product)

      fill_checkout_form(selected_product)

      click_on "Pay"
      click_on "Add to cart"

      expect(find_field("Checkbox field")["aria-invalid"]).to eq("true")
      expect(find_field("I accept")["aria-invalid"]).to eq("true")
    end
  end

  context "when the upsell offered product/variant is already in the cart" do
    it "doesn't offer the upsell" do
      visit upsell_product.long_url
      add_to_cart(upsell_product, option: "Untitled 1")
      visit upsell_product.long_url
      add_to_cart(upsell_product, option: "Untitled 2")

      fill_checkout_form(upsell_product)
      click_on "Pay"

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")
      expect(page).to have_section("Upsell product - Untitled 1")
      expect(page).to have_section("Upsell product - Untitled 2")
    end
  end

  context "when the cross-sell offered product is already in the cart" do
    it "doesn't offer the cross-sell" do
      visit product.long_url
      add_to_cart(product, option: "Untitled 1")
      visit selected_product.long_url
      add_to_cart(selected_product)

      check_out(selected_product)
    end
  end

  context "when the buyer has already purchased the offered product and variant" do
    let(:user) { create(:buyer_user) }
    let!(:purchase) { create(:purchase, link: product, variant_attributes: [product.alive_variants.first], purchaser: user) }

    it "doesn't offer the cross-sell" do
      login_as user
      visit selected_product.long_url
      add_to_cart(selected_product, logged_in_user: user)
      check_out(selected_product, logged_in_user: user)
    end

    context "when the buyer is the seller" do
      before do
        purchase.update!(purchaser: seller)
      end

      it "offers the cross-sell" do
        login_as seller
        visit selected_product.long_url
        add_to_cart(selected_product, logged_in_user: seller)
        fill_checkout_form(selected_product, logged_in_user: seller)
        click_on "Pay"
        within_modal "Cross-sell" do
          click_on "Add to cart"
        end

        expect(page).to have_text("Your purchase was successful!")
        within_section "Offered product (Untitled 1)" do
          expect(page).to have_text("This was a test purchase — you have not been charged (you are seeing this message because you are logged in as the creator).")
        end
        within_section "Product" do
          expect(page).to have_text("This was a test purchase — you have not been charged (you are seeing this message because you are logged in as the creator).")
        end
      end
    end
  end

  context "when the buyer has already purchased the offered variant" do
    let(:user) { create(:buyer_user) }
    let!(:purchase) { create(:purchase, link: upsell_product, variant_attributes: [upsell_product.alive_variants.second], purchaser: user) }

    it "doesn't offer the upsell" do
      login_as user
      visit upsell_product.long_url
      add_to_cart(upsell_product, option: "Untitled 1", logged_in_user: user)
      check_out(upsell_product, logged_in_user: user)
    end

    context "when the buyer is the seller" do
      before do
        purchase.update!(purchaser: seller)
      end

      it "offers the upsell" do
        login_as seller
        visit upsell_product.long_url
        add_to_cart(upsell_product, option: "Untitled 1", logged_in_user: seller)
        fill_checkout_form(upsell_product, logged_in_user: seller)
        click_on "Pay"
        within_modal "Upsell" do
          click_on "Upgrade"
        end

        expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to #{seller.email}")
        expect(page).to have_text("Upsell product - Untitled 2")
      end
    end
  end

  context "when the upsell has been deleted" do
    it "displays an error and allows the buyer to purchase without the upsell" do
      visit selected_product.long_url
      add_to_cart(selected_product)

      cross_sell.mark_deleted!

      fill_checkout_form(selected_product)
      click_on "Pay"

      expect do
        within_modal "Cross-sell" do
          click_on "Add to cart"
        end

        expect(page).to have_text("We charged your card and sent a receipt to test@gumroad.com")
      end.to change { Purchase.count }.by(1)

      purchase = Purchase.last
      expect(page).to have_link("View content", href: purchase.url_redirect.download_page_url)
      expect(page).to have_alert(text: "Sorry, this offer is no longer available.")

      expect(purchase.link).to eq(selected_product)

      visit checkout_index_path
      expect { check_out(product) }.to change { Purchase.count }.by(1)

      purchase = Purchase.last
      expect(purchase.link).to eq(product)
      expect(purchase.upsell_purchase).to be_nil
    end
  end

  context "when the buyer removes the cross-sell triggering product from the cart" do
    it "removes the cross-sell from the cart" do
      visit selected_product.long_url
      add_to_cart(selected_product)

      fill_checkout_form(selected_product)
      click_on "Pay"
      within_modal "Cross-sell" do
        click_on "Add to cart"
      end

      visit checkout_index_path
      expect(page).to have_text("Discounts US$-1", normalize_ws: true)
      within_cart_item "Product" do
        click_on "Remove"
      end
      check_out(product)

      purchase = Purchase.last
      expect(purchase.upsell_purchase).to be_nil
      expect(purchase.offer_code).to be_nil
      expect(purchase.price_cents).to eq(100)
    end
  end

  context "when the product has a content upsell" do
    it "allows checking out with the upsell product" do
      login_as seller
      product = create(:product, user: seller, name: "Sample product", price_cents: 1000)
      create(:purchase, :with_review, link: product)

      visit edit_link_path(product.unique_permalink)
      select_disclosure "Insert" do
        click_on "Upsell"
      end
      select_combo_box_option search: "Sample product", from: "Product"
      check "Add a discount to the offered product"
      choose "Fixed amount"
      fill_in "Fixed amount", with: "1"
      click_on "Insert"
      click_on "Save"
      expect(page).to have_alert(text: "Changes saved!")

      upsell = Upsell.last
      expect(upsell.product_id).to eq(product.id)
      expect(upsell.is_content_upsell).to be(true)
      expect(upsell.cross_sell).to be(true)
      expect(upsell.name).to eq(nil)
      expect(upsell.description).to eq(nil)

      expect(upsell.offer_code.amount_cents).to eq(100)
      expect(upsell.offer_code.amount_percentage).to be_nil
      expect(upsell.offer_code.universal).to be(false)
      expect(upsell.offer_code.product_ids).to eq([product.id])

      logout

      visit product.long_url
      click_on "Sample product"

      fill_checkout_form(product)
      click_on "Pay"
      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase = Purchase.last
      expect(purchase.link).to eq(product)
      expect(purchase.price_cents).to eq(900)
      expect(purchase.offer_code).to eq(upsell.offer_code)
      expect(purchase.offer_code.amount_cents).to eq(100)
      expect(purchase.upsell_purchase.upsell).to eq(upsell)
    end
  end
end
