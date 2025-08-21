# frozen_string_literal: true

describe("Product Page - Shipping to Virtual Countries", type: :system, js: true, shipping: true) do
  it "does not show the blurb if there is shipping, but no tax" do
    @product = create(:product, user: create(:user), require_shipping: true, price_cents: 100_00)

    @product.is_physical = true
    @product.price_currency_type = "usd"
    destination = ShippingDestination.new(country_code: ShippingDestination::Destinations::NORTH_AMERICA, one_item_rate_cents: 5_00, multiple_items_rate_cents: 1_00, is_virtual_country: true)
    @product.shipping_destinations << destination
    @product.save!

    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    check_out(@product) do
      expect(page).to have_text("Shipping rate US$5", normalize_ws: true)
      expect(page).to have_text("Total US$105", normalize_ws: true)
    end

    expect(Purchase.last.price_cents).to eq(10500)
    expect(Purchase.last.shipping_cents).to eq(500)
  end

  it "shows correct shipping cost with multiple quantities" do
    @product = create(:physical_product, user: create(:user), require_shipping: true, price_cents: 100_00)
    @product.price_currency_type = "usd"
    destination = ShippingDestination.new(country_code: ShippingDestination::Destinations::NORTH_AMERICA, one_item_rate_cents: 5_00, multiple_items_rate_cents: 1_00, is_virtual_country: true)
    @product.shipping_destinations << destination
    @product.save!

    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product, quantity: 2)
    check_out(@product) do
      expect(page).to have_text("Shipping rate US$6", normalize_ws: true)
      expect(page).to have_text("Total US$206", normalize_ws: true)
    end

    expect(Purchase.last.price_cents).to eq(20600)
    expect(Purchase.last.shipping_cents).to eq(600)
  end
end
