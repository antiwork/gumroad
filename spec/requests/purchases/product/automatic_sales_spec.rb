# frozen_string_literal: true

require "spec_helper"

describe "Automatic sales on product pages", type: :system, js: true do
  [1, 2].each do |quantity|
    it "keeps the displayed price through checkout for #{quantity} units with a minimum spend" do
      product = create(:product, price_cents: 1000, quantity_enabled: true)
      product.user.offer_codes.create!(code: "sale30", amount_percentage: 30, universal: true, auto_apply: true, sale_label: "Spring sale", minimum_amount_cents: 1500)

      visit "/l/#{product.unique_permalink}"
      fill_in "Quantity", with: quantity
      expect(page).to have_selector("[itemprop='price']", text: quantity == 1 ? "$10" : "$10 $7", exact_text: true, normalize_ws: true)
      if quantity == 1
        expect(page).to have_no_selector("[data-testid='sale-banner']")
      else
        expect(page).to have_selector("[data-testid='sale-banner']", text: "Spring sale")
      end
      click_on "I want this!"
      check_out(product)

      expect(Purchase.last.price_cents).to eq(quantity == 1 ? 1000 : 1400)
      expect(Purchase.last.quantity).to eq(quantity)
    end
  end

  it "shows a membership sale's end date before a tier is selected" do
    product = create(:membership_product_with_preset_tiered_pricing)
    product.user.offer_codes.create!(code: "member30", amount_percentage: 30, universal: true, auto_apply: true, sale_label: "Member sale", valid_at: 1.day.ago, expires_at: 30.days.from_now)

    visit "/l/#{product.unique_permalink}"

    expect(page).to have_selector("[data-testid='sale-banner']", text: "Member sale")
    expect(page).to have_selector("[role='status']", text: "This sale ends on")
  end

  it "removes the sale banner when the sale ends on an open page" do
    product = create(:membership_product_with_preset_tiered_pricing)
    product.user.offer_codes.create!(code: "member30", amount_percentage: 30, universal: true, auto_apply: true, sale_label: "Member sale", valid_at: 1.day.ago, expires_at: 20.seconds.from_now)

    visit "/l/#{product.unique_permalink}"
    expect(page).to have_selector("[data-testid='sale-banner']", text: "Member sale")

    expect(page).to have_no_selector("[data-testid='sale-banner']", wait: 30)
    expect(page).to have_selector("[role='status']", text: "Sorry, the discount code you wish to use is inactive.")
  end

  it "labels an option product only while the selected option meets the minimum spend" do
    product = create(:product, price_cents: 1000)
    category = create(:variant_category, link: product, title: "Edition")
    create(:variant, variant_category: category, name: "Basic")
    create(:variant, variant_category: category, name: "Deluxe", price_difference_cents: 1000)
    product.user.offer_codes.create!(code: "sale30", amount_percentage: 30, universal: true, auto_apply: true, sale_label: "Spring sale", minimum_amount_cents: 1500)

    visit "/l/#{product.unique_permalink}"
    expect(page).to have_selector("[data-testid='sale-banner']", text: "Spring sale")

    choose "Basic"
    expect(page).to have_no_selector("[data-testid='sale-banner']")

    choose "Deluxe"
    expect(page).to have_selector("[data-testid='sale-banner']", text: "Spring sale")
    click_on "I want this!"
    check_out(product)

    expect(Purchase.last.price_cents).to eq(1400)
  end

  describe "pay-what-you-want amounts" do
    let(:seller) { create(:compliant_user) }

    def quoted_price_cents
      quoted = Concurrent::Array.new
      subscriber = ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*, payload|
        quoted << payload[:params]["price_cents"] if payload[:action] == "selection_discounts"
      end
      yield
      quoted.to_a
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "opens a link with a decimal amount ready to buy at that amount" do
      product = create(:product, user: seller, name: "Pay what you want", price_cents: 500, customizable_price: true)
      seller.offer_codes.create!(code: "SHOP3", amount_cents: 300, currency_type: "usd", universal: true, products: [], auto_apply: true)

      quoted = quoted_price_cents do
        visit "#{product.long_url}?price=19.99"
        expect(page).to have_field("Name a fair price", with: "19.99")
        within(find(:article)) { expect(page).to have_link("I want this!") }
      end
      expect(page).to have_no_selector("[role='alert']")
      expect(quoted).to eq(["1999"])

      click_on "I want this!"
      expect(page).to have_cart_item("Pay what you want")
      expect(page).to have_text("Total US$19.99", normalize_ws: true)
    end

    context "when the quote for a typed amount is slow" do
      let(:product) { create(:product, user: seller, name: "Pay what you want", price_cents: 1000, customizable_price: true) }
      let(:release) { Concurrent::Event.new }

      before do
        seller.offer_codes.create!(code: "HALF", amount_percentage: 50, universal: true, products: [], auto_apply: true)
        held = release
        allow_any_instance_of(OfferCodesController).to receive(:selection_discounts).and_wrap_original do |original, *args|
          held.wait(15) if original.receiver.params[:price_cents].present?
          original.call(*args)
        end
      end

      after { release.set }

      def blur_amount(amount)
        visit product.long_url
        fill_in "Name a fair price", with: amount
        find(:label, "Name a fair price:").click
        within(find(:article)) { expect(page).to have_selector("a[aria-busy='true']:not([href])") }
        find_field("Name a fair price")
      end

      it "does not flag an amount above the sale's minimum while its quote loads, nor after it lands" do
        field = blur_amount("6")
        expect(field["aria-invalid"]).to eq("false")

        release.set
        within(find(:article)) { expect(page).to have_link("I want this!") }
        expect(field["aria-invalid"]).to eq("false")
      end

      it "flags an amount below the sale's minimum once its quote lands" do
        field = blur_amount("4")
        expect(field["aria-invalid"]).to eq("false")

        release.set
        expect(page).to have_selector("input[aria-invalid='true']")
        expect(field["aria-invalid"]).to eq("true")
      end
    end
  end

  it "keeps a qualifying buyer on the card's sale price when their existing-customer code takes less off" do
    seller = create(:compliant_user)
    product = create(:product, user: seller, price_cents: 1000)
    card_product = create(:product, user: seller, name: "Card product", price_cents: 1000)
    owned_product = create(:product, user: seller, price_cents: 2000)
    renewal = seller.offer_codes.create!(code: "RENEW10", amount_percentage: 10, products: [card_product],
                                         existing_customers_only: true, ownership_products: [owned_product])
    card_product.update!(default_offer_code: renewal)
    seller.offer_codes.create!(code: "SHOP30", amount_percentage: 30, universal: true, auto_apply: true)
    Link.import(refresh: true, force: true)
    cards = create(:seller_profile_products_section, seller:, product:, header: "More products", shown_products: [card_product.id])
    product.update!(sections: [cards.id])
    buyer = create(:user)
    create(:purchase, purchaser: buyer, link: owned_product, seller:, price_cents: 0)

    login_as buyer
    visit short_link_path(product)
    within_section "More products", section_element: :section do
      expect(page).to have_text("$10 $7", normalize_ws: true)
      click_on "Card product"
    end

    expect(page).to have_selector("[itemprop='price']", text: "$10 $7", exact_text: true, normalize_ws: true)
    expect(page).to have_selector("[data-testid='sale-banner']", text: "Sale")
    product_page_cta.click
    expect(page).to have_cart_item("Card product")
    expect(page).to have_text("Total US$7", normalize_ws: true)
  end

  it "weighs a qualifying buyer's existing-customer code against the sale on the tier they check out and edit" do
    seller = create(:compliant_user)
    product = create(:product, user: seller, price_cents: 1000)
    membership = create(:membership_product_with_preset_tiered_pricing, user: seller, name: "Target membership",
                                                                        recurrence_price_values: [
                                                                          { "monthly" => { enabled: true, price: 10 } },
                                                                          { "monthly" => { enabled: true, price: 100 } },
                                                                        ])
    owned_product = create(:product, user: seller, price_cents: 2000)
    renewal = seller.offer_codes.create!(code: "RENEW20", amount_percentage: 20, products: [membership],
                                         existing_customers_only: true, ownership_products: [owned_product])
    membership.update!(default_offer_code: renewal)
    seller.offer_codes.create!(code: "SHOP5", amount_cents: 500, currency_type: "usd", universal: true, products: [], auto_apply: true)
    Link.import(refresh: true, force: true)
    cards = create(:seller_profile_products_section, seller:, product:, header: "More products", shown_products: [membership.id])
    product.update!(sections: [cards.id])
    buyer = create(:user)
    create(:purchase, purchaser: buyer, link: owned_product, seller:, price_cents: 0)

    login_as buyer
    visit short_link_path(product)
    within_section "More products", section_element: :section do
      click_on "Target membership"
    end
    choose "Second Tier"
    product_page_cta.click

    expect(page).to have_cart_item("Target membership")
    expect(page).to have_text("Total US$80", normalize_ws: true)

    within_cart_item "Target membership" do
      select_disclosure "Edit" do
        choose "First Tier"
        click_on "Save changes"
      end
    end
    expect(page).to have_text("Total US$5", normalize_ws: true)
  end

  context "when a qualifying buyer's existing-customer default competes with the sale in the cart" do
    let(:seller) { create(:compliant_user) }
    let(:buyer) { create(:user) }
    let(:owned_product) { create(:product, user: seller, price_cents: 2000) }

    before { create(:purchase, purchaser: buyer, link: owned_product, seller:, price_cents: 0) }

    def make_default_for_existing_customers(product)
      renewal = seller.offer_codes.create!(code: "RENEW20", amount_percentage: 20, products: [product],
                                           existing_customers_only: true, ownership_products: [owned_product])
      product.update!(default_offer_code: renewal)
      renewal
    end

    def tiered_membership
      create(:membership_product_with_preset_tiered_pricing, user: seller, name: "Target membership",
                                                             recurrence_price_values: [
                                                               { "monthly" => { enabled: true, price: 10 } },
                                                               { "monthly" => { enabled: true, price: 100 } },
                                                             ])
    end

    it "records the lifetime existing-customer code, not a one-cycle sale that saves the same amount" do
      membership = tiered_membership
      renewal = make_default_for_existing_customers(membership)
      seller.offer_codes.create!(code: "SHOP2", amount_cents: 200, currency_type: "usd", universal: true, products: [],
                                 auto_apply: true, duration_in_billing_cycles: 1)

      login_as buyer
      visit membership.long_url
      add_to_cart(membership, option: "First Tier", offer_code: renewal)

      expect(page).to have_text("Total US$8", normalize_ws: true)
      check_out(membership, logged_in_user: buyer)

      purchase = membership.sales.successful.sole
      expect(purchase.offer_code.code).to eq("RENEW20")
      expect(purchase.price_cents).to eq(800)
    end

    def show_on_profile(product)
      profile_product = create(:product, user: seller, price_cents: 1000)
      Link.import(refresh: true, force: true)
      cards = create(:seller_profile_products_section, seller:, product: profile_product, header: "More products", shown_products: [product.id])
      profile_product.update!(sections: [cards.id])
      profile_product
    end

    def persisted_cart_holds?(products:, codes:)
      cart = Cart.fetch_by(user: buyer, browser_guid: nil)
      cart.present? && cart.alive_cart_products.map(&:product).sort_by(&:id) == products.sort_by(&:id) &&
        cart.discount_codes.pluck("code").sort == codes.sort
    end

    it "keeps weighing the existing-customer code after the buyer adds a product that only has the sale, and after a reload" do
      product = create(:product, user: seller, name: "Sale-only product", price_cents: 1000)
      membership = tiered_membership
      make_default_for_existing_customers(membership)
      sale = seller.offer_codes.create!(code: "SHOP5", amount_cents: 500, currency_type: "usd", universal: true, products: [], auto_apply: true)
      profile_product = show_on_profile(membership)

      login_as buyer
      visit short_link_path(profile_product)
      within_section "More products", section_element: :section do
        click_on "Target membership"
      end
      choose "Second Tier"
      product_page_cta.click
      expect(page).to have_cart_item("Target membership")
      expect(page).to have_text("Total US$80", normalize_ws: true)
      wait_until_true(sleep_interval: 0.2) { persisted_cart_holds?(products: [membership], codes: %w[RENEW20 SHOP5]) }

      visit product.long_url
      add_to_cart(product, offer_code: sale)
      expect(page).to have_cart_item("Sale-only product")
      expect(page).to have_text("Total US$85", normalize_ws: true)
      wait_until_true(sleep_interval: 0.2) { persisted_cart_holds?(products: [membership, product], codes: %w[RENEW20 SHOP5]) }

      visit checkout_path
      expect(page).to have_cart_item("Target membership")
      expect(page).to have_cart_item("Sale-only product")
      expect(page).to have_text("Total US$85", normalize_ws: true)
      expect(persisted_cart_holds?(products: [membership, product], codes: %w[RENEW20 SHOP5])).to be(true)
    end

    it "advertises each tier at its own best code on the product page and charges that in the cart" do
      membership = tiered_membership
      make_default_for_existing_customers(membership)
      seller.offer_codes.create!(code: "SHOP5", amount_cents: 500, currency_type: "usd", universal: true, products: [], auto_apply: true)
      profile_product = show_on_profile(membership)

      login_as buyer
      visit short_link_path(profile_product)
      within_section "More products", section_element: :section do
        click_on "Target membership"
      end
      expect(page).to have_selector("[role='radio']", text: "$10 $5 a month First Tier", normalize_ws: true)
      expect(page).to have_selector("[role='radio']", text: "$100 $80 a month Second Tier", normalize_ws: true)
      choose "First Tier"
      expect(page).to have_selector("[data-testid='sale-banner']", text: "$5 off First Tier")
      choose "Second Tier"
      expect(page).to have_selector("[role='status']", text: "20% off Second Tier will be applied at checkout (Code RENEW20)")
      expect(Rack::Utils.parse_query(URI.parse(product_page_cta[:href]).query)["code"]).to eq("RENEW20")
      expect(page).to have_no_selector("[data-testid='sale-banner']")

      product_page_cta.click
      expect(page).to have_cart_item("Target membership")
      expect(page).to have_text("Total US$80", normalize_ws: true)
    end

    context "when the best code depends on the quantity" do
      let(:product) { create(:product, user: seller, name: "Quantity product", price_cents: 1000, quantity_enabled: true) }

      before do
        make_default_for_existing_customers(product)
        seller.offer_codes.create!(code: "ONCE5", amount_cents: 500, currency_type: "usd", universal: true, products: [], auto_apply: true, once_per_cart: true)
      end

      def hold_selection_quotes(quantity)
        held = Concurrent::Event.new
        @release_selection_quotes = Concurrent::Event.new
        release = @release_selection_quotes
        allow_any_instance_of(OfferCodesController).to receive(:selection_discounts).and_wrap_original do |original, *args|
          if original.receiver.params[:quantity] == quantity.to_s
            held.set
            release.wait(15)
          end
          original.call(*args)
        end
        held
      end

      after { @release_selection_quotes&.set }

      def cta_code(label = "I want this!")
        within(find(:article)) { Rack::Utils.parse_query(URI.parse(find(:link, label)[:href]).query)["code"] }
      end

      it "holds the buy button while the page re-quotes a new quantity, and drops an answer for an earlier quantity" do
        login_as buyer
        visit product.long_url
        expect(page).to have_selector("[itemprop='price']", text: "$10 $5", exact_text: true, normalize_ws: true)
        expect(cta_code).to eq("ONCE5")

        held = hold_selection_quotes(2)
        fill_in "Quantity", with: 2
        expect(held.wait(10)).to be(true)
        within(find(:article)) do
          expect(page).to have_selector("a[aria-busy='true']:not([href])", text: "I want this!")
          expect(page).to have_no_link("I want this!")
        end
        expect(page).to have_selector("[itemprop='price']", text: "$10", exact_text: true, normalize_ws: true)

        fill_in "Quantity", with: 3
        expect(page).to have_selector("[itemprop='price']", text: "$10 $8", exact_text: true, normalize_ws: true)
        expect(cta_code).to eq("RENEW20")
        @release_selection_quotes.set
        expect(page).to have_no_selector("a[aria-busy='true']")
        expect(cta_code).to eq("RENEW20")
        expect(page).to have_selector("[itemprop='price']", text: "$10 $8", exact_text: true, normalize_ws: true)

        click_on "I want this!"
        expect(page).to have_cart_item("Quantity product")
        expect(page).to have_text("Total US$24", normalize_ws: true)
      end

      it "waits without a false failure while the buyer clears the quantity and types a new one" do
        quoted_quantities = Concurrent::Array.new
        subscriber = ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*, payload|
          quoted_quantities << payload[:params]["quantity"] if payload[:action] == "selection_discounts"
        end

        login_as buyer
        visit product.long_url
        expect(page).to have_selector("[itemprop='price']", text: "$10 $5", exact_text: true, normalize_ws: true)
        quantity = find_field("Quantity")
        quantity.send_keys(:backspace)
        within(find(:article)) { expect(page).to have_no_link("I want this!") }
        expect(page).to have_no_selector("[role='alert']")

        quantity.send_keys("3")
        expect(page).to have_selector("[itemprop='price']", text: "$10 $8", exact_text: true, normalize_ws: true)
        expect(cta_code).to eq("RENEW20")
        expect(page).to have_no_selector("[role='alert']")
        expect(quoted_quantities).to eq(["3"])
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      end

      it "offers no checkout link while a re-quote fails, and recovers when the buyer tries again" do
        failing = Concurrent::AtomicBoolean.new(true)
        allow_any_instance_of(OfferCodesController).to receive(:selection_discounts).and_wrap_original do |original, *args|
          failing.true? ? original.receiver.head(:internal_server_error) : original.call(*args)
        end

        login_as buyer
        visit product.long_url
        expect(page).to have_selector("[itemprop='price']", text: "$10 $5", exact_text: true, normalize_ws: true)
        fill_in "Quantity", with: 4
        expect(page).to have_alert(text: "We couldn't check the discount for this selection.")
        within(find(:article)) { expect(page).to have_no_link("I want this!") }
        expect(page).to have_selector("[itemprop='price']", text: "$10", exact_text: true, normalize_ws: true)

        failing.make_false
        click_on "Try again"
        expect(page).to have_no_alert(text: "We couldn't check the discount for this selection.")
        expect(page).to have_selector("[itemprop='price']", text: "$10 $8", exact_text: true, normalize_ws: true)
        expect(cta_code).to eq("RENEW20")

        click_on "I want this!"
        expect(page).to have_cart_item("Quantity product")
        expect(page).to have_text("Total US$32", normalize_ws: true)
      end
    end

    it "prices renting and buying at their own best code, and charges the bought price after switching back" do
      product = create(:product, user: seller, name: "Rental product", price_cents: 10_000, purchase_type: :buy_and_rent, rental_price_cents: 1000)
      make_default_for_existing_customers(product)
      seller.offer_codes.create!(code: "SHOP5", amount_cents: 500, currency_type: "usd", universal: true, products: [], auto_apply: true)
      cta_code = ->(label) { within(find(:article)) { Rack::Utils.parse_query(URI.parse(find(:link, label)[:href]).query)["code"] } }

      login_as buyer
      visit product.long_url
      expect(page).to have_radio_button("Buy", text: /\$100\s+\$80/)
      expect(page).to have_radio_button("Rent", text: /\$10\s+\$5/)
      expect(cta_code.("I want this!")).to eq("RENEW20")

      choose "Rent"
      expect(cta_code.("Rent")).to eq("SHOP5")
      expect(page).to have_radio_button("Rent", text: /\$10\s+\$5/)

      choose "Buy"
      expect(cta_code.("I want this!")).to eq("RENEW20")
      click_on "I want this!"
      expect(page).to have_cart_item("Rental product")
      expect(page).to have_text("Total US$80", normalize_ws: true)
    end

    # Holds the page's first cart save on the server until a later save has been written, and the
    # arrival's quotes until that first save has reached the server, so it is still in flight when
    # the codes are ready.
    it "persists the arrival's codes while the page's first cart save is still being written" do
      membership = tiered_membership
      make_default_for_existing_customers(membership)
      seller.offer_codes.create!(code: "SHOP5", amount_cents: 500, currency_type: "usd", universal: true, products: [], auto_apply: true)
      profile_product = show_on_profile(membership)

      login_as buyer
      visit short_link_path(profile_product)
      within_section "More products", section_element: :section do
        click_on "Target membership"
      end
      choose "Second Tier"

      first_save_reached_server = Concurrent::Event.new
      later_save_written = Concurrent::Event.new
      first_save = Concurrent::AtomicBoolean.new(true)
      saves_written = Concurrent::AtomicFixnum.new
      allow_any_instance_of(OfferCodesController).to receive(:compute_discount).and_wrap_original do |original, *args|
        first_save_reached_server.wait(3)
        original.call(*args)
      end
      allow_any_instance_of(CheckoutController).to receive(:update).and_wrap_original do |original, *args|
        held = first_save.make_false
        first_save_reached_server.set
        later_save_written.wait(3) if held
        original.call(*args)
      ensure
        saves_written.increment
        later_save_written.set unless held
      end
      product_page_cta.click

      expect(page).to have_cart_item("Target membership")
      expect(page).to have_text("Total US$80", normalize_ws: true)
      wait_until_true(sleep_interval: 0.2) { saves_written.value >= 2 }
      # The save that answers with the sale may be followed by one that stores it, so wait for the full set.
      wait_until_true(sleep_interval: 0.2) { persisted_cart_holds?(products: [membership], codes: %w[RENEW20 SHOP5]) }

      visit checkout_path
      expect(page).to have_cart_item("Target membership")
      expect(page).to have_text("Total US$80", normalize_ws: true)
      expect(persisted_cart_holds?(products: [membership], codes: %w[RENEW20 SHOP5])).to be(true)
    end

    it "advertises the existing-customer code on the option where it beats both purchasing power parity and the sale" do
      seller.update!(purchasing_power_parity_enabled: true)
      product = create(:product, user: seller, name: "Target product", price_cents: 1000)
      editions = create(:variant_category, link: product, title: "Edition")
      create(:variant, variant_category: editions, name: "Basic", price_difference_cents: 0)
      premium = create(:variant, variant_category: editions, name: "Premium", price_difference_cents: 9000)
      make_default_for_existing_customers(product)
      seller.offer_codes.create!(code: "SHOP5", amount_cents: 500, currency_type: "usd", universal: true, products: [], auto_apply: true)
      profile_product = show_on_profile(product)
      PurchasingPowerParityService.new.set_factor("LV", 0.9)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("109.110.31.255")

      login_as buyer
      visit short_link_path(profile_product)
      within_section "More products", section_element: :section do
        click_on "Target product"
      end
      choose "Premium"
      query = Rack::Utils.parse_query(URI.parse(product_page_cta[:href]).query)
      expect(query["option"]).to eq(premium.external_id)
      expect(query["code"]).to eq("RENEW20")
      product_page_cta.click

      expect(page).to have_cart_item("Target product")
      expect(page).to have_text("Total US$80", normalize_ws: true)
      expect(page).to have_no_alert(text: "purchasing power parity discount is greater")
    end

    def edit_cart_item(name, &block)
      within_cart_item name do
        select_disclosure "Edit" do
          block.call
          click_on "Save changes"
        end
      end
    end

    def bulk_sale_product(loyalty: true)
      product = create(:product, user: seller, name: "Target product", price_cents: 1000, quantity_enabled: true)
      make_default_for_existing_customers(product) if loyalty
      seller.offer_codes.create!(code: "BULK50", amount_percentage: 50, universal: true, products: [], auto_apply: true, minimum_quantity: 2)
      [product, show_on_profile(product)]
    end

    def open_from_profile(profile_product)
      visit short_link_path(profile_product)
      within_section "More products", section_element: :section do
        click_on "Target product"
      end
    end

    def cta_code
      Rack::Utils.parse_query(URI.parse(product_page_cta[:href]).query)["code"]
    end

    # Holds cart saves for this quantity on the server until the example releases them. The save's
    # answer is what quotes the sale for the cart.
    def hold_cart_saves(quantity)
      held = Concurrent::Event.new
      @release_cart_saves = Concurrent::Event.new
      release = @release_cart_saves
      allow_any_instance_of(CheckoutController).to receive(:update).and_wrap_original do |original, *args|
        items = original.receiver.params.dig(:cart, :items).to_a
        if items.map { _1[:quantity].to_i } == [quantity]
          held.set
          release.wait(15)
        end
        original.call(*args)
      end
      held
    end

    after { @release_cart_saves&.set }

    it "applies a sale with a minimum quantity once a cart edit meets it, also after a reload" do
      _product, profile_product = bulk_sale_product

      login_as buyer
      open_from_profile(profile_product)
      expect(cta_code).to eq("RENEW20")
      product_page_cta.click
      expect(page).to have_cart_item("Target product")
      expect(page).to have_text("Total US$8", normalize_ws: true)

      edit_cart_item("Target product") { fill_in "Quantity", with: 2 }
      expect(page).to have_text("Total US$10", normalize_ws: true)
      edit_cart_item("Target product") { fill_in "Quantity", with: 1 }
      expect(page).to have_text("Total US$8", normalize_ws: true)
      wait_until_true(sleep_interval: 0.2) { Cart.fetch_by(user: buyer, browser_guid: nil)&.alive_cart_products&.sole&.quantity == 1 }

      visit checkout_path
      expect(page).to have_text("Total US$8", normalize_ws: true)
      edit_cart_item("Target product") { fill_in "Quantity", with: 2 }
      expect(page).to have_text("Total US$10", normalize_ws: true)
    end

    it "applies the sale when the buyer raises the quantity before the arrival's save returns" do
      _product, profile_product = bulk_sale_product
      held = hold_cart_saves(1)

      login_as buyer
      open_from_profile(profile_product)
      product_page_cta.click
      expect(held.wait(10)).to be(true)
      edit_cart_item("Target product") { fill_in "Quantity", with: 2 }
      @release_cart_saves.set

      expect(page).to have_text("Total US$10", normalize_ws: true)
      expect(page).to have_button("Pay", disabled: false)
    end

    it "keeps Pay closed until the save for a raised quantity returns" do
      _product, profile_product = bulk_sale_product

      login_as buyer
      open_from_profile(profile_product)
      product_page_cta.click
      expect(page).to have_text("Total US$8", normalize_ws: true)
      expect(page).to have_button("Pay", disabled: false)

      held = hold_cart_saves(2)
      edit_cart_item("Target product") { fill_in "Quantity", with: 2 }
      expect(held.wait(10)).to be(true)
      expect(page).to have_text("Total US$16", normalize_ws: true)
      expect(page).not_to have_button("Pay", disabled: false, wait: 3)

      @release_cart_saves.set
      expect(page).to have_text("Total US$10", normalize_ws: true)
      expect(page).to have_button("Pay", disabled: false)
    end

    it "applies a held save for a raised quantity after a guest types their email" do
      product, profile_product = bulk_sale_product(loyalty: false)

      open_from_profile(profile_product)
      fill_in "Quantity", with: 2
      expect(cta_code).to eq("BULK50")
      product_page_cta.click
      expect(page).to have_text("Total US$10", normalize_ws: true)
      edit_cart_item("Target product") { fill_in "Quantity", with: 1 }
      wait_until_true(sleep_interval: 0.2) do
        cart = CartProduct.alive.find_by(product:)&.cart
        cart&.alive_cart_products&.sole&.quantity == 1 && cart.discount_codes.pluck("code") == %w[BULK50]
      end

      visit checkout_path
      expect(page).to have_text("Total US$10", normalize_ws: true)
      held = hold_cart_saves(2)
      edit_cart_item("Target product") { fill_in "Quantity", with: 2 }
      expect(held.wait(10)).to be(true)
      fill_in "Email address", with: "guest@example.com"
      @release_cart_saves.set

      expect(page).to have_text("Total US$10", normalize_ws: true)
      expect(page).to have_text("BULK50", normalize_ws: true)
    end

    it "keeps the defaults when purchasing power parity wins at first, so a cheaper tier gets the loyalty code" do
      seller.update!(purchasing_power_parity_enabled: true)
      membership = tiered_membership
      loyalty = seller.offer_codes.create!(code: "RENEW5", amount_cents: 500, currency_type: "usd", products: [membership],
                                           existing_customers_only: true, ownership_products: [owned_product])
      membership.update!(default_offer_code: loyalty)
      seller.offer_codes.create!(code: "SHOP20", amount_percentage: 20, universal: true, products: [], auto_apply: true)
      profile_product = show_on_profile(membership)
      PurchasingPowerParityService.new.set_factor("LV", 0.7)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("109.110.31.255")

      login_as buyer
      visit short_link_path(profile_product)
      within_section "More products", section_element: :section do
        click_on "Target membership"
      end
      choose "Second Tier"
      expect(Rack::Utils.parse_query(URI.parse(product_page_cta[:href]).query)).not_to have_key("code")
      product_page_cta.click
      expect(page).to have_cart_item("Target membership")
      expect(page).to have_text("Total US$70", normalize_ws: true)

      edit_cart_item("Target membership") { choose "First Tier" }
      expect(page).to have_text("Total US$5", normalize_ws: true)
      expect(page).to have_no_alert(text: "purchasing power parity discount is greater")
    end

    # The product page leaves the code off its CTA once PPP wins, so this arrives by checkout link.
    it "weighs the existing-customer code when purchasing power parity beats the sale in a checkout link" do
      seller.update!(purchasing_power_parity_enabled: true)
      product = create(:product, user: seller, name: "Target product", price_cents: 1000)
      editions = create(:variant_category, link: product, title: "Edition")
      create(:variant, variant_category: editions, name: "Basic", price_difference_cents: 0)
      premium = create(:variant, variant_category: editions, name: "Premium", price_difference_cents: 9000)
      make_default_for_existing_customers(product)
      seller.offer_codes.create!(code: "SHOP5", amount_cents: 500, currency_type: "usd", universal: true, products: [], auto_apply: true)
      PurchasingPowerParityService.new.set_factor("LV", 0.9)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("109.110.31.255")

      login_as buyer
      visit checkout_path(product: product.unique_permalink, option: premium.external_id, quantity: 1, code: "SHOP5")

      expect(page).to have_cart_item("Target product")
      expect(page).to have_text("Total US$80", normalize_ws: true)
      expect(page).to have_no_alert(text: "purchasing power parity discount is greater")
    end
  end

  it "labels profile cards and the featured product with the sale" do
    seller = create(:user)
    product = create(:product, user: seller, price_cents: 1000)
    card_product = create(:product, user: seller, name: "Card product", price_cents: 1000)
    featured_product = create(:product, user: seller, name: "Featured product", price_cents: 2000)
    seller.offer_codes.create!(code: "spring30", amount_percentage: 30, universal: true, auto_apply: true, sale_label: "Spring sale")
    Link.import(refresh: true, force: true)
    cards = create(:seller_profile_products_section, seller:, product:, header: "More products", shown_products: [card_product.id])
    featured = create(:seller_profile_featured_product_section, seller:, product:, header: "Featured", featured_product_id: featured_product.id)
    product.update!(sections: [cards.id, featured.id])

    visit short_link_path(product)

    within_section "More products", section_element: :section do
      expect(page).to have_selector("[data-testid='sale-label']", text: "Spring sale")
      expect(page).to have_text("$10 $7", normalize_ws: true)
    end
    within_section "Featured", section_element: :section do
      expect(page).to have_selector("[data-testid='sale-banner']", text: "Spring sale")
      expect(page).to have_text("$20 $14", normalize_ws: true)
    end
  end

  context "when a cart edit changes which lines a sale covers" do
    let(:seller) { create(:compliant_user) }

    def click_checkout_cta
      within(find(:article)) { find("a[href*='/checkout']", match: :first).click }
    end

    it "applies a sale that already covers one line to another line once its quantity meets the minimum" do
      first_product = create(:product, user: seller, name: "First product", price_cents: 1000, quantity_enabled: true)
      second_product = create(:product, user: seller, name: "Second product", price_cents: 1000, quantity_enabled: true)
      seller.offer_codes.create!(code: "BULK50", amount_percentage: 50, universal: true, products: [], auto_apply: true, minimum_quantity: 2)

      visit first_product.long_url
      fill_in "Quantity", with: 2
      click_checkout_cta
      expect(page).to have_text("Total US$10", normalize_ws: true)

      visit second_product.long_url
      click_checkout_cta
      expect(page).to have_cart_item("Second product")
      expect(page).to have_text("Total US$20", normalize_ws: true)

      within_cart_item "Second product" do
        select_disclosure "Edit" do
          fill_in "Quantity", with: 2
          click_on "Save changes"
        end
      end
      expect(page).to have_text("Total US$20", normalize_ws: true)
    end

    it "gives a checkout link's code the sale instead when the sale takes more off" do
      product = create(:product, user: seller, name: "Linked product", price_cents: 1000)
      seller.offer_codes.create!(code: "URL10", amount_percentage: 10, products: [product])
      seller.offer_codes.create!(code: "SHOP30", amount_percentage: 30, universal: true, products: [], auto_apply: true)

      visit checkout_path(product: product.unique_permalink, code: "URL10")
      expect(page).to have_cart_item("Linked product")
      expect(page).to have_text("Total US$7", normalize_ws: true)
    end

    it "keeps the sale for a guest when purchasing power parity wins at first, so a cheaper tier gets the sale" do
      seller.update!(purchasing_power_parity_enabled: true)
      membership = create(:membership_product_with_preset_tiered_pricing, user: seller, name: "Target membership",
                                                                          recurrence_price_values: [
                                                                            { "monthly" => { enabled: true, price: 10 } },
                                                                            { "monthly" => { enabled: true, price: 100 } },
                                                                          ])
      seller.offer_codes.create!(code: "SHOP5", amount_cents: 500, currency_type: "usd", universal: true, products: [], auto_apply: true)
      PurchasingPowerParityService.new.set_factor("LV", 0.7)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("109.110.31.255")

      visit membership.long_url
      choose "Second Tier"
      click_checkout_cta
      expect(page).to have_cart_item("Target membership")
      expect(page).to have_text("Total US$70", normalize_ws: true)

      within_cart_item "Target membership" do
        select_disclosure "Edit" do
          choose "First Tier"
          click_on "Save changes"
        end
      end
      expect(page).to have_text("Total US$5", normalize_ws: true)
    end

    [false, true].each do |saved_card|
      it "keeps Pay closed until the cart save quotes the sale for a product added without a code#{" with a saved card" if saved_card}" do
        buyer = create(:user)
        buyer.update!(credit_card: create(:credit_card, user: buyer)) if saved_card
        first_product = create(:product, user: seller, name: "First product", price_cents: 1000)
        second_product = create(:product, user: seller, name: "Second product", price_cents: 1000)
        seller.offer_codes.create!(code: "SHOP50", amount_percentage: 50, universal: true, products: [], auto_apply: true)

        login_as buyer
        visit first_product.long_url
        click_checkout_cta
        expect(page).to have_text("Total US$5", normalize_ws: true)
        wait_until_true(sleep_interval: 0.2) { Cart.fetch_by(user: buyer, browser_guid: nil)&.discount_codes&.pluck("code") == %w[SHOP50] }

        held = Concurrent::Event.new
        release = Concurrent::Event.new
        allow_any_instance_of(CheckoutController).to receive(:update).and_wrap_original do |original, *args|
          held.set
          release.wait(15)
          original.call(*args)
        end
        # Capybara's visit waits for ajax, which the held save never finishes.
        page.execute_script("window.location.href = arguments[0]", checkout_path(product: second_product.unique_permalink))
        expect(held.wait(10)).to be(true)
        expect(page).to have_cart_item("Second product")
        if saved_card
          expect(page).to have_text("Total US$15", normalize_ws: true)
        else
          within_payment_element_frame { expect(page).to have_field("Card number", visible: :all, wait: 20) }
        end
        expect(page).not_to have_button("Pay", disabled: false, wait: 3)

        release.set
        expect(page).to have_text("Total US$10", normalize_ws: true)
        expect(page).to have_button("Pay", disabled: false)
      ensure
        release&.set
      end
    end
  end
end
