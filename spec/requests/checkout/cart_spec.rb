# frozen_string_literal: true

require "spec_helper"

describe "Checkout cart", :js, type: :system do
  before do
    @product = create(:product, price_cents: 1000, quantity_enabled: true)
    @pwyw_product = create(:product, price_cents: 1000, customizable_price: true, thumbnail: create(:thumbnail))
    @versioned_product = create(:product_with_digital_versions, thumbnail: create(:thumbnail))
    @membership_product = create(:membership_product_with_preset_tiered_pricing, recurrence_price_values: [
                                   {
                                     "monthly": { enabled: true, price: 2 },
                                     "yearly": { enabled: true, price: 4 }
                                   },
                                   {
                                     "monthly": { enabled: true, price: 5 },
                                     "yearly": { enabled: true, price: 10 }
                                   }
                                 ])
    @rental_product = create(:product, purchase_type: "buy_and_rent", price_cents: 500, rental_price_cents: 300)
  end

  describe "edit popover" do
    it "updates the option" do
      @variant1 = @versioned_product.variant_categories.first.variants.first
      @variant2 = @versioned_product.variant_categories.first.variants.second
      @variant2.update!(price_difference_cents: 100)

      visit @versioned_product.long_url
      add_to_cart(@versioned_product, option: @variant1.name)
      within_cart_item(@versioned_product.name) do
        expect(page).to have_link(@versioned_product.name, href: @versioned_product.long_url)
        expect(page).to have_selector("a[href='#{@versioned_product.long_url}'] > img[src='#{@versioned_product.thumbnail.url}']")
        expect(page).to have_text("US$1")
        select_disclosure "Configure" do
          choose @variant2.name
          click_on "Save changes"
        end
      end
      within_cart_item(@versioned_product.name) do
        expect(page).to have_link(@versioned_product.name, href: @versioned_product.long_url)
        expect(page).to have_selector("a[href='#{@versioned_product.long_url}'] > img[src='#{@versioned_product.thumbnail.url}']")
        expect(page).to have_text("US$2")
        expect(page).to have_text("Version: #{@variant2.name}")
      end

      visit @versioned_product.long_url
      add_to_cart(@versioned_product, option: @variant1.name)
      within_cart_item(@versioned_product.name) do
        select_disclosure "Configure" do
          choose @variant2.name
          click_on "Save changes"
        end
        expect(page).to have_alert(text: "You already have this item in your cart.")
        choose @variant1.name
        expect(page).to_not have_alert
      end
      check_out(@versioned_product, cart_item_count: 2)
    end

    it "updates the recurrence" do
      visit @membership_product.long_url
      add_to_cart(@membership_product, recurrence: "Yearly", option: @membership_product.variant_categories.first.variants.first.name)
      within_cart_item(@membership_product.name) do
        expect(page).to have_link(@membership_product.name, href: @membership_product.long_url)
        expect(page).to have_selector("a[href='#{@membership_product.long_url}'] > img")
        expect(page).to have_text("US$4 Yearly", normalize_ws: true)
        select_disclosure "Configure" do
          select "Monthly", from: "Recurrence"
          click_on "Save changes"
        end
      end
      within_cart_item(@membership_product.name) do
        expect(page).to have_link(@membership_product.name, href: @membership_product.long_url)
        expect(page).to have_text("US$2 Monthly", normalize_ws: true)
        expect(page).to have_text("Membership: Monthly")
      end
      check_out(@membership_product)
    end

    it "updates the quantity" do
      visit @product.long_url
      add_to_cart(@product)
      within_cart_item(@product.name) do
        expect(page).to have_link(@product.name, href: @product.long_url)
        expect(page).to have_selector("a[href='#{@product.long_url}'] > img")
        expect(page).to have_text("US$10")
        select_disclosure "Configure" do
          fill_in "Quantity", with: 4
          click_on "Save changes"
        end
      end
      within_cart_item(@product.name) do
        expect(page).to have_link(@product.name, href: @product.long_url)
        expect(page).to have_text("US$40")
        expect(page).to have_text("Qty: 4")
      end
      check_out(@product)
    end

    it "updates the PWYW price" do
      visit @pwyw_product.long_url
      add_to_cart(@pwyw_product, pwyw_price: 10)
      within_cart_item(@pwyw_product.name) do
        expect(page).to have_link(@pwyw_product.name, href: @pwyw_product.long_url)
        expect(page).to have_selector("a[href='#{@pwyw_product.long_url}'] > img[src='#{@pwyw_product.thumbnail.url}']")
        expect(page).to have_text("US$10")
        select_disclosure "Configure" do
          fill_in "Name a fair price", with: "5"
          click_on "Save changes"
          expect(find_field("Name a fair price")["aria-invalid"]).to eq("true")
          fill_in "Name a fair price", with: "20"
          click_on "Save changes"
        end
      end
      within_cart_item(@pwyw_product.name) do
        expect(page).to have_link(@pwyw_product.name, href: @pwyw_product.long_url)
        expect(page).to have_selector("a[href='#{@pwyw_product.long_url}'] > img[src='#{@pwyw_product.thumbnail.url}']")
        expect(page).to have_text("US$20")
      end
      check_out(@pwyw_product)
    end

    it "updates the rental" do
      visit @rental_product.long_url
      add_to_cart(@rental_product)
      within_cart_item(@rental_product.name) do
        expect(page).to have_link(@rental_product.name, href: @rental_product.long_url)
        expect(page).to have_selector("a[href='#{@rental_product.long_url}'] > img")
        expect(page).to have_text("US$5")
        select_disclosure "Configure" do
          choose "Rent"
          click_on "Save changes"
        end
      end
      within_cart_item(@rental_product.name) do
        expect(page).to have_link(@rental_product.name, href: @rental_product.long_url)
        expect(page).to have_text("US$3")
      end
      check_out(@rental_product)
    end

    describe "cart persistence" do
      let(:wait) { Selenium::WebDriver::Wait.new }

      context "when adding a product with a discount code" do
        let(:offer_code) { create(:percentage_offer_code, code: "get-it-for-free", amount_percentage: 100, products: [@product], user: @product.user) }

        it "calculates the discount and adds it to the cart" do
          buyer = create(:user)
          cart = create(:cart, user: buyer)

          login_as buyer
          visit "#{@product.long_url}/#{offer_code.code}"

          add_to_cart(@product, offer_code:)

          # Wait for the discount to be successfully verified - the card form will be removed when the product is free
          expect(page).to have_text("Discounts get-it-for-free US$-10", normalize_ws: true)
          expect(page).not_to have_selector(:fieldset, "Card information")

          expect(cart.reload.discount_codes).to eq([{ "code" => "get-it-for-free", "fromUrl" => true }])
        end
      end

      it "persists the cart for a logged-in user and creates a different cart for the guest user on logout" do
        buyer = create(:user)
        login_as buyer
        visit @product.long_url
        add_to_cart(@product)
        wait.until { buyer.reload.alive_cart.present? }
        user_cart = Cart.alive.sole
        expect(user_cart.user).to eq(buyer)
        expect(user_cart.alive_cart_products.sole.product_id).to eq(@product.id)
        check_out(@product, logged_in_user: buyer, email: buyer.email)
        expect(user_cart.reload).to be_deleted
        expect(user_cart.email).to eq(buyer.email)
        expect(user_cart.order_id).to eq(Order.last.id)
        new_buyer_cart = buyer.reload.alive_cart
        expect(new_buyer_cart.browser_guid).to eq(user_cart.browser_guid)
        expect(new_buyer_cart.alive_cart_products.count).to eq(0)

        click_on "Back to Library"
        toggle_disclosure buyer.username
        click_on "Logout"

        visit @membership_product.long_url
        add_to_cart(@membership_product, recurrence: "Yearly", option: @membership_product.variants.first.name)
        wait.until { Cart.alive.count == 2 }
        guest_cart = Cart.last
        expect(guest_cart).to be_alive
        expect(guest_cart.user).to be_nil
        expect(guest_cart.alive_cart_products.sole.product_id).to eq(@membership_product.id)
        check_out(@membership_product)
        expect(guest_cart.reload).to be_deleted
        expect(guest_cart.email).to eq("test@gumroad.com")
        expect(guest_cart.order_id).to eq(Order.last.id)
        new_guest_cart = Cart.last
        expect(new_guest_cart).to be_alive
        expect(new_guest_cart.user).to be_nil
        expect(new_guest_cart.alive_cart_products.count).to eq(0)

        expect(new_buyer_cart.reload).to be_alive
        expect(new_buyer_cart.alive_cart_products.count).to eq(0)
      end

      it "creates and updates a cart during checkout for a logged-in user" do
        buyer = create(:user)
        login_as buyer
        visit @membership_product.long_url

        add_to_cart(@membership_product, recurrence: "Yearly", option: @membership_product.variant_categories.first.variants.first.name)

        wait.until { buyer.reload.alive_cart.present? && buyer.alive_cart.cart_products.exists? }

        cart = buyer.alive_cart
        cart_product = cart.cart_products.sole

        expect(cart_product).to have_attributes(
          product: @membership_product,
          recurrence: BasePrice::Recurrence::YEARLY,
          option: @membership_product.variant_categories.first.variants.first
        )

        within_cart_item(@membership_product.name) do
          select_disclosure "Configure" do
            select "Monthly", from: "Recurrence"
            choose @membership_product.variants.second.name
            click_on "Save changes"
          end
        end

        wait.until { cart_product.reload.deleted? }

        new_cart_product = cart.cart_products.alive.sole

        expect(new_cart_product.reload).to have_attributes(
          recurrence: BasePrice::Recurrence::MONTHLY,
          option: @membership_product.variants.second
        )

        visit @product.long_url
        add_to_cart(@product)

        wait.until { cart.cart_products.alive.count == 2 }
        expect(cart.cart_products.alive.first.product).to eq @membership_product
        expect(cart.cart_products.alive.second.product).to eq @product

        check_out(@product, logged_in_user: buyer)

        expect(cart.reload).to be_deleted
        # A new empty cart is created after checkout
        wait.until { buyer.reload.alive_cart.present? }
        expect(buyer.alive_cart.cart_products).to be_empty
      end

      it "creates a new cart with the failed item when an item fails after checkout" do
        buyer = create(:user)
        login_as buyer
        visit @membership_product.long_url

        add_to_cart(@membership_product, recurrence: "Yearly", option: @membership_product.variants.first.name)

        visit @product.long_url
        add_to_cart(@product)

        check_out(@product, logged_in_user: buyer, error: "The price just changed! Refresh the page for the updated price.") do
          @product.update!(price_cents: 100_00)
        end
        expect(page).to have_link("View content")

        wait.until { buyer.carts.count == 2 }

        expect(buyer.alive_cart.cart_products.sole.product).to eq @product

        refresh

        within_cart_item(@product.name) do
          expect(page).to have_text("US$100")
        end
      end

      it "merges the guest cart with the user's cart on login" do
        buyer = create(:user)
        buyer_cart = create(:cart, user: buyer, browser_guid: "old-browser-guid", email: "john@example.com")
        create(:cart_product, cart: buyer_cart, product: @product)

        visit @membership_product.long_url
        add_to_cart(@membership_product, recurrence: "Yearly", option: @membership_product.variants.first.name)
        wait.until { Cart.alive.count == 2 }
        guest_cart = Cart.alive.last
        expect(guest_cart.user).to be_nil
        expect(guest_cart.alive_cart_products.count).to eq(1)

        visit login_path
        fill_in "Email", with: buyer.email
        fill_in "Password", with: buyer.password
        click_on "Login"
        wait_for_ajax
        expect(page).to_not have_current_path(login_path)
        expect(buyer_cart.reload).to be_alive
        expect(guest_cart.reload).to be_deleted
        expect(buyer_cart.alive_cart_products.pluck(:product_id, :option_id)).to eq([[@product.id, nil], [@membership_product.id, @membership_product.variants.first.id]])
        expect(buyer_cart.browser_guid).to_not eq("old-browser-guid")
        expect(buyer_cart.browser_guid).to eq(guest_cart.browser_guid)
      end

      describe "when adding products to the cart" do
        let(:buyer) { create(:buyer_user) }
        let(:seller) { create(:named_seller, name: "John Doe") }
        let(:product1) { create(:product, user: seller) }
        let(:product2) { create(:product, user: seller, name: "Another product") }

        describe "when cart has the maximum allowed products" do
          before do
            login_as buyer
            visit product1.long_url
            click_on text: "I want this!"
            wait.until { buyer.reload.alive_cart.present? }
            create_list(:cart_product, 49, cart: buyer.alive_cart)
          end

          it "shows an error message on adding a product to the cart" do
            visit product2.long_url
            click_on text: "I want this!"
            expect_alert_message "You cannot add more than 50 products to the cart."
            expect(page).to_not have_cart_item("Another product")
            expect(buyer.alive_cart.reload.alive_cart_products.find_by(product_id: product2.id)).to be_nil
          end
        end
      end

      context "when the checkout page URL contains `cart_id` query param" do
        context "when user is logged in" do
          it "shows user's cart without any modifications" do
            buyer = create(:user)
            user_cart = create(:cart, user: buyer)
            create(:cart_product, cart: user_cart, product: create(:product, name: "Product 1"))
            another_cart = create(:cart, :guest)
            create(:cart_product, cart: another_cart, product: create(:product, name: "Product 2"))

            login_as buyer
            visit checkout_index_path(cart_id: another_cart.external_id)
            expect(page).to have_current_path(checkout_index_path)
            expect(page).to have_text("Product 1")
            expect(page).to_not have_text("Product 2")

            expect(Cart.alive.count).to eq(2)
            expect(user_cart.reload.alive_cart_products.sole.product.name).to eq("Product 1")
            expect(another_cart.reload.alive_cart_products.sole.product.name).to eq("Product 2")
          end
        end

        context "when user is not logged in" do
          context "when the cart matching the `cart_id` query param belongs to a user" do
            it "redirects to the login page and merges the current guest cart with the logged in user's cart" do
              user_cart = create(:cart)
              create(:cart_product, cart: user_cart, product: create(:product, name: "Product 1"))
              product2 = create(:product, name: "Product 2")
              visit product2.long_url
              add_to_cart(product2)
              wait.until { Cart.alive.count == 2 }
              guest_cart = Cart.alive.last

              visit checkout_index_path(cart_id: user_cart.external_id)
              expect(page).to have_current_path(login_path(email: user_cart.user.email, next: checkout_index_path(referrer: UrlService.discover_domain_with_protocol)))
              fill_in "Password", with: user_cart.user.password
              click_on "Login"
              wait_for_ajax
              expect(page).to have_current_path(checkout_index_path)
              expect(Cart.alive.count).to eq(1)
              expect(guest_cart.reload).to be_deleted
              expect(user_cart.reload).to be_alive
              expect(user_cart.alive_cart_products.map(&:product).map(&:name)).to match_array(["Product 1", "Product 2"])
              expect(user_cart.browser_guid).to eq(guest_cart.browser_guid)
              expect(page).to have_text("Product 1")
              expect(page).to have_text("Product 2")
            end
          end

          context "when the cart matching the `cart_id` query param has `browser_guid` different from the current `_gumroad_guid` cookie value" do
            it "merges the current guest cart with the cart matching the `cart_id` query param" do
              cart = create(:cart, :guest, browser_guid: SecureRandom.uuid)
              create(:cart_product, cart:, product: create(:product, name: "Product 1"))
              current_guest_cart = create(:cart, :guest)
              create(:cart_product, cart: current_guest_cart, product: create(:product, name: "Product 2"))

              visit root_path
              current_browser_guid = Capybara.current_session.driver.browser.manage.all_cookies.find { _1[:name] == "_gumroad_guid" }&.[](:value)
              current_guest_cart.update!(browser_guid: current_browser_guid)

              visit checkout_index_path(cart_id: cart.external_id)
              expect(page).to have_current_path(checkout_index_path)
              expect(page).to have_text("Product 1")
              expect(page).to have_text("Product 2")
              expect(Cart.alive.count).to eq(1)
              expect(current_guest_cart.reload).to be_deleted
              expect(cart.reload.alive_cart_products.map(&:product).map(&:name)).to match_array(["Product 1", "Product 2"])
              expect(cart.reload.browser_guid).to eq(current_browser_guid)
            end
          end
        end
      end
    end

    context "when there are no configuration inputs" do
      it "hides the edit popover" do
        @product.update!(quantity_enabled: false)

        visit @product.long_url
        add_to_cart(@product)
        expect(page).to_not have_disclosure("Configure")
      end
    end
  end
end
