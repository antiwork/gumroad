# frozen_string_literal: true

require("spec_helper")

describe "Purchasing power parity", type: :system, js: true do
  before do
    @user = create(:user, purchasing_power_parity_enabled: true, display_offer_code_field: true)
    @product = create(:product, price_cents: 999, user: @user)
    @membership = create(:membership_product_with_preset_tiered_pricing, user: @user)
    PurchasingPowerParityService.new.set_factor("LV", 0.49)
    allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("109.110.31.255")
  end

  describe "classic product" do
    context "when the product has purchasing_power_parity_disabled" do
      before do
        @product.update! purchasing_power_parity_disabled: true
      end

      it "doesn't apply the PPP discount" do
        visit @product.long_url

        expect(page).to_not have_selector("[itemprop='price']", text: "$4.90")
        expect(page).to_not have_selector("[role='status']", text: "This product supports purchasing power parity.")

        add_to_cart(@product)
        check_out(@product, credit_card: { number: "4000004280000005" }, zip_code: nil)

        purchase = Purchase.last

        expect(purchase.price_cents).to eq(999)
        expect(purchase.is_purchasing_power_parity_discounted).to eq(false)
      end
    end

    context "when the card country matches the IP country" do
      it "applies the PPP discount" do
        visit @product.long_url

        expect(page).to have_selector("[itemprop='price']", text: "$9.99 $4.90")
        expect(page).to have_selector("[role='status']", text: "This product supports purchasing power parity. Because you're located in Latvia, the price has been discounted by 51% to $4.90.")
        add_to_cart(@product)
        check_out(@product, credit_card: { number: "4000004280000005" }, zip_code: nil)

        purchase = Purchase.last

        expect(purchase.price_cents).to eq(490)
        expect(purchase.is_purchasing_power_parity_discounted).to eq(true)
      end
    end

    context "when the card country doesn't match the IP country" do
      it "doesn't apply the PPP discount" do
        visit @product.long_url

        expect(page).to have_selector("[itemprop='price']", text: "$9.99 $4.90")
        expect(page).to have_selector("[role='status']", text: "This product supports purchasing power parity. Because you're located in Latvia, the price has been discounted by 51% to $4.90.")
        add_to_cart(@product)
        check_out(@product, zip_code: nil, error: "In order to apply a purchasing power parity discount, you must use a card issued in the country you are in. Please try again with a local card, or remove the discount during checkout.")
        visit checkout_index_path
        ppp_pill = find_button("Purchasing power parity discount")
        ppp_pill.hover
        expect(ppp_pill).to have_tooltip(text: "This discount is applied based on the cost of living in your country.")
        ppp_pill.click
        check_out(@product, zip_code: nil)

        purchase = Purchase.last

        expect(purchase.price_cents).to eq(999)
        expect(purchase.is_purchasing_power_parity_discounted).to eq(false)

        # Test that the discount is reset after purchase and when a new item is added to the cart
        visit @product.long_url
        add_to_cart(@product)
        click_on "Purchasing power parity discount"
        visit @product.long_url
        add_to_cart(@product)
        expect(page).to have_button("Purchasing power parity discount")
      end
    end

    context "when the price gets discounted below the currency's minimum" do
      it "rounds the price up to the minimum" do
        @product.update!(price_cents: 100)

        visit @product.long_url

        expect(page).to have_selector("[itemprop='price']", text: "$1 $0.99")
        expect(page).to have_selector("[role='status']", text: "This product supports purchasing power parity. Because you're located in Latvia, the price has been discounted by 1% to $0.99.")
        add_to_cart(@product)
        check_out(@product, credit_card: { number: "4000004280000005" }, zip_code: nil)

        purchase = Purchase.last

        expect(purchase.price_cents).to eq(99)
        expect(purchase.is_purchasing_power_parity_discounted).to eq(true)
      end
    end

    context "when the seller has set a limit to the PPP discount" do
      it "caps the PPP discount at the limit" do
        @user.update!(purchasing_power_parity_limit: 30)
        visit @product.long_url

        expect(page).to have_selector("[itemprop='price']", text: "$9.99 $6.99")
        expect(page).to have_selector("[role='status']", text: "This product supports purchasing power parity. Because you're located in Latvia, the price has been discounted by 30% to $6.99.")
        add_to_cart(@product)
        check_out(@product, credit_card: { number: "4000004280000005" }, zip_code: nil)

        purchase = Purchase.last

        expect(purchase.price_cents).to eq(699)
        expect(purchase.is_purchasing_power_parity_discounted).to eq(true)
      end
    end
  end

  describe "PWYW product" do
    context "when the product has purchasing_power_parity_disabled" do
      before do
        @product.update!(purchasing_power_parity_disabled: true, customizable_price: true)
      end

      it "doesn't apply the PPP discount" do
        visit @product.long_url

        expect(page).to_not have_selector("[itemprop='price']", text: "$4.90+")
        expect(page).to_not have_selector("[role='status']", text: "This product supports purchasing power parity.")

        add_to_cart(@product, pwyw_price: 12.00)
        check_out(@product, credit_card: { number: "4000004280000005" }, zip_code: nil)

        purchase = Purchase.last

        expect(purchase.price_cents).to eq(1200)
        expect(purchase.is_purchasing_power_parity_discounted).to eq(false)
      end
    end

    it "applies the PPP discount" do
      @product.update!(customizable_price: true)
      visit @product.long_url

      expect(page).to have_selector("[itemprop='price']", text: "$9.99 $4.90+")
      expect(page).to have_selector("[role='status']", text: "This product supports purchasing power parity. Because you're located in Latvia, the price has been discounted by 51% to $4.90.")
      add_to_cart(@product, pwyw_price: 5.44, ppp_factor: 0.49)
      check_out(@product, credit_card: { number: "4000004280000005" }, zip_code: nil)

      purchase = Purchase.last

      expect(purchase.price_cents).to eq(544)
      expect(purchase.is_purchasing_power_parity_discounted).to eq(true)
    end
  end

  describe "membership product" do
    context "when the product has purchasing_power_parity_disabled" do
      before do
        @membership.update!(purchasing_power_parity_disabled: true)
      end

      it "doesn't apply the PPP discount" do
        visit @membership.long_url
        expect(page).to_not have_selector("[role='status']", text: "This product supports purchasing power parity.")
        expect(page).to_not have_radio_button("First Tier", text: "$1.47 a month")
        expect(page).to_not have_radio_button("Second Tier", text: "$2.45 a month")

        add_to_cart(@membership, option: "First Tier")
        check_out(@membership, credit_card: { number: "4000004280000005" }, zip_code: nil)

        purchase = Purchase.last

        expect(purchase.price_cents).to eq(300)
        expect(purchase.is_purchasing_power_parity_discounted).to eq(false)

        select_disclosure "Membership" do
          click_on "Manage"
        end

        expect(page).to have_current_path(magic_link_subscription_path(purchase.subscription.external_id))
        expect(page).to have_text "Send magic link"
        click_on "Send magic link"
        expect(page).to have_current_path(magic_link_subscription_path(purchase.subscription.external_id))
        expect(page).to have_text "We've sent a link to"

        visit manage_subscription_path(purchase.subscription.external_id, token: purchase.reload.subscription.token)

        expect(page).to have_radio_button("First Tier", text: "$3 a month")
      end
    end

    it "applies the PPP discount" do
      visit @membership.long_url
      expect(page).to have_selector("[role='status']", text: "This product supports purchasing power parity. Because you're located in Latvia, the price has been discounted by 51% to $1.47.")
      expect(page).to have_radio_button("First Tier", text: "$3 $1.47 a month")
      expect(page).to have_radio_button("Second Tier", text: "$5 $2.45 a month")

      add_to_cart(@membership, option: "First Tier")
      check_out(@membership, credit_card: { number: "4000004280000005" }, zip_code: nil)

      purchase = Purchase.last

      expect(purchase.price_cents).to eq(147)
      expect(purchase.is_purchasing_power_parity_discounted).to eq(true)

      select_disclosure "Membership" do
        click_on "Manage"
      end

      expect(page).to have_current_path(magic_link_subscription_path(purchase.subscription.external_id))
      expect(page).to have_text "Send magic link"
      click_on "Send magic link"
      expect(page).to have_current_path(magic_link_subscription_path(purchase.subscription.external_id))
      expect(page).to have_text "We've sent a link to"

      visit manage_subscription_path(purchase.subscription.external_id, token: purchase.reload.subscription.token)

      expect(page).to have_radio_button("First Tier", text: "$1.47 a month")
    end
  end

  describe "discounted product" do
    context "when the offer code provides a lesser discount than PPP" do
      before do
        @offer_code = create(:offer_code, products: [@product])
      end

      context "when the product has purchasing_power_parity_disabled" do
        before do
          @product.update!(purchasing_power_parity_disabled: true)
        end

        it "applies the offer code but not the PPP discount" do
          visit "#{@product.long_url}/#{@offer_code.code}"

          expect(page).to_not have_selector("[itemprop='price']", text: "$4.90")
          expect(page).to_not have_selector("[role='status']", text: "This product supports purchasing power parity.")
          add_to_cart(@product, offer_code: @offer_code)
          fill_in "Discount code", with: @offer_code.code
          click_on "Apply"
          expect(page).to_not have_alert(text: "The offer code will not be applied because the purchasing power parity discount is greater than the offer code discount for all products.")
          expect(page).to have_selector("[aria-label='Discount code']", text: @offer_code.code)

          check_out(@product, credit_card: { number: "4000004280000005" }, zip_code: nil)

          purchase = Purchase.last

          expect(purchase.price_cents).to eq(899)
          expect(purchase.is_purchasing_power_parity_discounted).to eq(false)
        end
      end

      it "applies the PPP discount" do
        visit "#{@product.long_url}/#{@offer_code.code}"

        expect(page).to have_selector("[itemprop='price']", text: "$9.99 $4.90")
        expect(page).to have_selector("[role='status']", text: "This product supports purchasing power parity. Because you're located in Latvia, the price has been discounted by 51% to $4.90. This discount will be applied because it is greater than the offer code discount.")
        add_to_cart(@product)
        fill_in "Discount code", with: @offer_code.code
        click_on "Apply"
        expect(page).to have_alert(text: "The offer code will not be applied because the purchasing power parity discount is greater than the offer code discount for all products.")
        expect(page).to_not have_selector("[aria-label='Discount code']", text: @offer_code.code)

        check_out(@product, credit_card: { number: "4000004280000005" }, zip_code: nil)

        purchase = Purchase.last

        expect(purchase.price_cents).to eq(490)
        expect(purchase.is_purchasing_power_parity_discounted).to eq(true)
      end
    end

    context "when the offer code provides a greater discount than PPP for some but not all products" do
      before do
        @product2 = create(:product, price_cents: 1000)
        @offer_code = create(:offer_code, products: [@product])
        @offer_code2 = create(:offer_code, code: @offer_code.code, amount_cents: 900, products: [@product2])
      end

      it "only applies the PPP discount to the product for which the offer code discount is less" do
        visit @product.long_url
        add_to_cart(@product)
        visit @product2.long_url
        add_to_cart(@product2)

        fill_in "Discount code", with: @offer_code.code
        click_on "Apply"
        expect(page).to have_alert(text: "The offer code will not be applied to some products for which the purchasing power parity discount is greater than the offer code discount.")
        expect(page).to have_selector("[aria-label='Discount code']", text: @offer_code.code)

        expect(page).to have_text("Discounts Purchasing power parity discount #{@offer_code.code} US$-14.09", normalize_ws: true)

        check_out(@product, credit_card: { number: "4000004280000005" }, zip_code: nil)

        first_purchase = Purchase.second_to_last
        second_purchase = Purchase.last

        expect(first_purchase.price_cents).to eq(100)
        expect(first_purchase.is_purchasing_power_parity_discounted).to eq(false)
        expect(second_purchase.price_cents).to eq(490)
        expect(second_purchase.is_purchasing_power_parity_discounted).to eq(true)
      end
    end

    context "when the offer code provides a greater discount than PPP" do
      before do
        @offer_code = create(:offer_code, amount_cents: 900, products: [@product])
      end

      it "doesn't apply the PPP discount" do
        visit "#{@product.long_url}/#{@offer_code.code}"

        expect(page).to have_selector("[itemprop='price']", text: "$9.99 $0.99")
        expect(page).to have_selector("[role='status']", text: "$9 off will be applied at checkout (Code #{@offer_code.code.upcase})")
        expect(page).to_not have_selector("[role='status']", text: "This product supports purchasing power parity.")

        add_to_cart(@product, offer_code: @offer_code)
        check_out(@product, credit_card: { number: "4000004280000005" }, zip_code: nil)

        purchase = Purchase.last

        expect(purchase.price_cents).to eq(99)
        expect(purchase.is_purchasing_power_parity_discounted).to eq(false)
      end
    end
  end

  describe "free product" do
    before do
      @product.update(customizable_price: true, price_cents: 0)
    end

    it "does not apply the PPP discount" do
      visit @product.long_url

      expect(page).to have_selector("[itemprop='price']", text: "$0")
      expect(page).to_not have_selector("[role='status']", text: "This product supports purchasing power parity.")

      add_to_cart(@product, pwyw_price: 0)
      check_out(@product, is_free: true)

      purchase = Purchase.last

      expect(purchase.price_cents).to eq(0)
      expect(purchase.is_purchasing_power_parity_discounted).to eq(false)
    end
  end

  describe "cross-sell product with discount" do
    before do
      @cross_sell_product = create(:product, name: "Cross-sell product", user: @user, price_cents: 1000)
      @cross_sell = create(:upsell, seller: @user, product: @cross_sell_product, selected_products: [@product], offer_code: create(:offer_code, user: @user, products: [@cross_sell_product]), cross_sell: true)
    end

    it "doesn't apply the PPP discount" do
      visit @product.long_url

      expect(page).to have_selector("[itemprop='price']", text: "$9.99 $4.90")
      expect(page).to have_selector("[role='status']", text: "This product supports purchasing power parity. Because you're located in Latvia, the price has been discounted by 51% to $4.90.")

      add_to_cart(@product)
      fill_checkout_form(@product, credit_card: { number: "4000004280000005" }, zip_code: nil)
      click_on "Pay"

      within_modal "Take advantage of this excellent offer!" do
        click_on "Add to cart"
      end

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase = Purchase.second_to_last
      expect(purchase.price_cents).to eq(490)
      expect(purchase.is_purchasing_power_parity_discounted).to eq(true)

      cross_sell_purchase = Purchase.last
      expect(cross_sell_purchase.purchase_state).to eq("successful")
      expect(cross_sell_purchase.displayed_price_cents).to eq(900)
      expect(cross_sell_purchase.offer_code).to eq(@cross_sell.offer_code)
      expect(cross_sell_purchase.upsell_purchase.selected_product).to eq(@product)
      expect(cross_sell_purchase.upsell_purchase.upsell).to eq(@cross_sell)
    end
  end

  context "when payment verification is disabled" do
    before do
      @user.update!(purchasing_power_parity_payment_verification_disabled: true)
    end

    it "doesn't require the customer's payment method to match their country" do
      visit @product.long_url

      expect(page).to have_selector("[itemprop='price']", text: "$9.99 $4.90")
      expect(page).to have_selector("[role='status']", text: "This product supports purchasing power parity. Because you're located in Latvia, the price has been discounted by 51% to $4.90.")
      add_to_cart(@product)
      check_out(@product, zip_code: nil)

      purchase = Purchase.last

      expect(purchase.price_cents).to eq(490)
      expect(purchase.is_purchasing_power_parity_discounted).to eq(true)
    end

    context "when the product has purchasing_power_parity_disabled" do
      before do
        @product.update! purchasing_power_parity_disabled: true
      end

      it "doesn't apply the PPP discount" do
        visit @product.long_url

        expect(page).to_not have_selector("[itemprop='price']", text: "$4.90")
        expect(page).to_not have_selector("[role='status']", text: "This product supports purchasing power parity.")

        add_to_cart(@product)
        check_out(@product, credit_card: { number: "4000004280000005" }, zip_code: nil)

        purchase = Purchase.last

        expect(purchase.price_cents).to eq(999)
        expect(purchase.is_purchasing_power_parity_discounted).to eq(false)
      end
    end
  end
end
