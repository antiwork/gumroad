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

    # The saved cart is what the first arrival leaves behind: Second Tier with both defaults.
    it "keeps weighing the existing-customer code after the buyer adds a product that only has the sale, and after a reload" do
      product = create(:product, user: seller, name: "Sale-only product", price_cents: 1000)
      membership = tiered_membership
      make_default_for_existing_customers(membership)
      sale = seller.offer_codes.create!(code: "SHOP5", amount_cents: 500, currency_type: "usd", universal: true, products: [], auto_apply: true)
      cart = create(:cart, user: buyer, discount_codes: [{ code: "SHOP5", fromUrl: true }, { code: "RENEW20", fromUrl: true }])
      create(:cart_product, cart:, product: membership, option: membership.alive_variants.find_by!(name: "Second Tier"),
                            recurrence: "monthly", price: 10_000)

      login_as buyer
      visit checkout_path
      expect(page).to have_text("Total US$80", normalize_ws: true)

      visit product.long_url
      add_to_cart(product, offer_code: sale)
      expect(page).to have_cart_item("Sale-only product")
      expect(page).to have_text("Total US$85", normalize_ws: true)

      wait_until_true(sleep_interval: CheckoutPresenter::CART_SAVE_DEBOUNCE_DURATION_IN_SECONDS) do
        cart.reload.alive_cart_products.count == 2 && cart.discount_codes.pluck("code").sort == %w[RENEW20 SHOP5]
      end
      visit checkout_path
      expect(page).to have_cart_item("Target membership")
      expect(page).to have_text("Total US$85", normalize_ws: true)
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
