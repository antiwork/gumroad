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
    click_on "Add to cart"
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
    click_on "Add to cart"

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
      click_on "Add to cart"
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
      click_on "Add to cart"

      expect(page).to have_cart_item("Target membership")
      expect(page).to have_text("Total US$80", normalize_ws: true)
      wait_until_true(sleep_interval: 0.2) { saves_written.value >= 2 }
      expect(persisted_cart_holds?(products: [membership], codes: %w[RENEW20 SHOP5])).to be(true)
    end

    it "weighs the existing-customer code when the product page leaves the code off because purchasing power parity beats the sale" do
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
      within find(:article) do
        query = Rack::Utils.parse_query(URI.parse(find(:link, "Add to cart")[:href]).query)
        expect(query["option"]).to eq(premium.external_id)
        expect(query).not_to have_key("code")
      end
      click_on "Add to cart"

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
      within(find(:article)) { Rack::Utils.parse_query(URI.parse(find(:link, "Add to cart")[:href]).query)["code"] }
    end

    # Holds BULK50 quotes for this quantity on the server until the example releases them.
    def hold_sale_quotes(quantity)
      held = Concurrent::Event.new
      @release_sale_quotes = Concurrent::Event.new
      release = @release_sale_quotes
      allow_any_instance_of(OfferCodesController).to receive(:compute_discount).and_wrap_original do |original, *args|
        params = original.receiver.params
        if params[:code] == "BULK50" && params[:products].to_unsafe_h.values.map { _1["quantity"].to_i } == [quantity]
          held.set
          release.wait(15)
        end
        original.call(*args)
      end
      held
    end

    after { @release_sale_quotes&.set }

    it "applies a sale with a minimum quantity once a cart edit meets it, also after a reload" do
      _product, profile_product = bulk_sale_product

      login_as buyer
      open_from_profile(profile_product)
      expect(cta_code).to eq("RENEW20")
      click_on "Add to cart"
      expect(page).to have_cart_item("Target product")
      expect(page).to have_text("Total US$8", normalize_ws: true)

      edit_cart_item("Target product") { fill_in "Quantity", with: 2 }
      expect(page).to have_text("Total US$10", normalize_ws: true)
      edit_cart_item("Target product") { fill_in "Quantity", with: 1 }
      expect(page).to have_text("Total US$8", normalize_ws: true)
      wait_until_true(sleep_interval: 0.2) do
        cart = Cart.fetch_by(user: buyer, browser_guid: nil)
        cart&.alive_cart_products&.sole&.quantity == 1 && cart.discount_codes.pluck("code").sort == %w[BULK50 RENEW20]
      end

      visit checkout_path
      expect(page).to have_text("Total US$8", normalize_ws: true)
      edit_cart_item("Target product") { fill_in "Quantity", with: 2 }
      expect(page).to have_text("Total US$10", normalize_ws: true)
    end

    it "applies the sale when the buyer raises the quantity before the arrival's quotes return" do
      _product, profile_product = bulk_sale_product
      held = hold_sale_quotes(1)

      login_as buyer
      open_from_profile(profile_product)
      click_on "Add to cart"
      expect(held.wait(10)).to be(true)
      edit_cart_item("Target product") { fill_in "Quantity", with: 2 }
      @release_sale_quotes.set

      expect(page).to have_text("Total US$10", normalize_ws: true)
      expect(page).to have_button("Pay", disabled: false)
    end

    it "keeps Pay closed until the sale's quote for a raised quantity returns" do
      _product, profile_product = bulk_sale_product

      login_as buyer
      open_from_profile(profile_product)
      click_on "Add to cart"
      expect(page).to have_text("Total US$8", normalize_ws: true)
      expect(page).to have_button("Pay", disabled: false)

      held = hold_sale_quotes(2)
      edit_cart_item("Target product") { fill_in "Quantity", with: 2 }
      expect(held.wait(10)).to be(true)
      expect(page).to have_text("Total US$16", normalize_ws: true)
      expect(page).not_to have_button("Pay", disabled: false, wait: 3)

      @release_sale_quotes.set
      expect(page).to have_text("Total US$10", normalize_ws: true)
      expect(page).to have_button("Pay", disabled: false)
    end

    it "applies a held quote for a raised quantity after a guest types their email" do
      product, profile_product = bulk_sale_product(loyalty: false)

      open_from_profile(profile_product)
      fill_in "Quantity", with: 2
      expect(cta_code).to eq("BULK50")
      click_on "Add to cart"
      expect(page).to have_text("Total US$10", normalize_ws: true)
      edit_cart_item("Target product") { fill_in "Quantity", with: 1 }
      wait_until_true(sleep_interval: 0.2) do
        cart = CartProduct.alive.find_by(product:)&.cart
        cart&.alive_cart_products&.sole&.quantity == 1 && cart.discount_codes.pluck("code") == %w[BULK50]
      end

      visit checkout_path
      expect(page).to have_text("Total US$10", normalize_ws: true)
      held = hold_sale_quotes(2)
      edit_cart_item("Target product") { fill_in "Quantity", with: 2 }
      expect(held.wait(10)).to be(true)
      fill_in "Email address", with: "guest@example.com"
      @release_sale_quotes.set

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
      within find(:article) do
        expect(Rack::Utils.parse_query(URI.parse(find(:link, "Add to cart")[:href]).query)).not_to have_key("code")
      end
      click_on "Add to cart"
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
end
