# frozen_string_literal: true

describe("Product Page - Shipping with offer codes", type: :system, js: true, shipping: true) do
  it "allows the 50% offer code to only affect the product cost and not the shipping in USD" do
    @product = create(:product, user: create(:user), require_shipping: true, price_cents: 100_00)
    @offer_code = create(:percentage_offer_code, products: [@product], amount_percentage: 50, user: @product.user)

    @product.is_physical = true
    @product.price_currency_type = "usd"
    @product.shipping_destinations << ShippingDestination.new(country_code: "US", one_item_rate_cents: 2000, multiple_items_rate_cents: 1000)
    @product.save!

    visit "/l/#{@product.unique_permalink}/#{@offer_code.code}"
    add_to_cart(@product, offer_code: @offer_code)
    check_out(@product, should_verify_address: true) do
      expect(page).to have_text("Shipping rate US$20", normalize_ws: true)
    end

    expect(page).to have_alert("Your purchase was successful!")

    expect(Purchase.last.price_cents).to eq(7000)
    expect(Purchase.last.shipping_cents).to eq(2000)
  end

  it "allows the 100% offer code to affect only the product cost and not the shipping in USD" do
    @product = create(:product, user: create(:user, display_offer_code_field: true), require_shipping: true, price_cents: 100_00)
    @offer_code = create(:percentage_offer_code, products: [@product], amount_percentage: 100, user: @product.user)

    @product.is_physical = true
    @product.price_currency_type = "usd"
    @product.shipping_destinations << ShippingDestination.new(country_code: "US", one_item_rate_cents: 2000, multiple_items_rate_cents: 1000)
    @product.save!

    visit "/l/#{@product.unique_permalink}/#{@offer_code.code}"
    add_to_cart(@product, offer_code: @offer_code)
    check_out(@product, offer_code: @offer_code.code, should_verify_address: true) do
      expect(page).to have_text("Shipping rate US$20", normalize_ws: true)
    end

    expect(page).to have_alert("Your purchase was successful!")

    expect(Purchase.last.price_cents).to eq(2000)
    expect(Purchase.last.shipping_cents).to eq(2000)
  end

  it "only has the $50 offer code affect the product and not shipping and taxes" do
    @user = create(:user_with_compliance_info)

    @product = create(
      :product,
      user: @user,
      require_shipping: true,
      price_cents: 100_00,
      price_currency_type: "gbp",
      is_physical: true
    )
    @product.shipping_destinations << ShippingDestination.new(country_code: "US", one_item_rate_cents: 2000, multiple_items_rate_cents: 1000)
    @product.save!

    @offer_code = create(:offer_code, products: [@product], currency_type: "gbp", amount_cents: 50_00, user: @product.user)

    visit "/l/#{@product.unique_permalink}/#{@offer_code.code}"
    add_to_cart(@product, offer_code: @offer_code)
    check_out(@product, address: { street: "3029 W Sherman Rd", city: "San Tan Valley", state: "AZ", zip_code: "85144" }, should_verify_address: true) do
      expect(page).to have_text("Subtotal US$153.24", normalize_ws: true)
      expect(page).to have_text("Sales tax US$5.13", normalize_ws: true)
      expect(page).to have_text("Shipping rate US$30.65", normalize_ws: true)
      expect(page).to have_text("Total US$112.40", normalize_ws: true)
    end

    expect(page).to have_alert("Your purchase was successful!")

    expect(page).to have_text(@product.name)
    expect(Purchase.last.price_cents).to eq(10727)
    expect(Purchase.last.shipping_cents).to eq(3065)
    expect(Purchase.last.gumroad_tax_cents).to eq(513)
  end

  context "with a 100% offer code and free shipping" do
    before do
      @product = create(:product, require_shipping: true, price_cents: 1000, is_physical: true, shipping_destinations: [ShippingDestination.new(country_code: "US", one_item_rate_cents: 0, multiple_items_rate_cents: 0)], user: create(:user, display_offer_code_field: true))
      @offer_code = create(:percentage_offer_code, products: [@product], amount_percentage: 100)
    end

    it "allows purchase" do
      visit "#{@product.long_url}/#{@offer_code.code}"
      add_to_cart(@product, offer_code: @offer_code)
      check_out(@product, offer_code: @offer_code.code, is_free: true, should_verify_address: true)
      expect(Purchase.last.price_cents).to eq(0)
      expect(Purchase.last.shipping_cents).to eq(0)
    end
  end
end
