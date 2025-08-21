# frozen_string_literal: true

require("spec_helper")
require "timeout"

describe("Variant Purchases from product page", type: :system, js: true) do
  before do
    @user = create(:named_user)
    @product = create(:product, user: @user, custom_receipt: "<h1>Hello</h1>")
  end

  it "initializes variants from legacy query params" do
    variant_category = create(:variant_category, link: @product, title: "type")
    variants = [["default", 0], ["type 1 (test)", 150], ["type 2, extra", 200], ["type 3 (test, extra) + x", 300]]
    variants.each do |name, price_difference_cents|
      create(:variant, variant_category:, name:, price_difference_cents:)
    end

    # paren in option name should work fine, if escaped
    visit "/l/#{@product.unique_permalink}?variant=#{js_style_encode_uri_component("type 1 (test)")}"
    expect(page).to have_radio_button("type 1 (test)", checked: true)

    # comma in option name should work fine, if escaped
    visit "/l/#{@product.unique_permalink}?variant=#{js_style_encode_uri_component("type 2, extra")}"
    expect(page).to have_radio_button("type 2, extra", checked: true)

    # comma and parens together and a plus sign
    visit "/l/#{@product.unique_permalink}?variant=#{js_style_encode_uri_component("type 3 (test, extra) + x")}"
    expect(page).to have_radio_button("type 3 (test, extra) + x", checked: true)
  end

  it "displays variant select with product name if only tier is untitled" do
    link = create(:product, name: "Membership", is_recurring_billing: true, subscription_duration: :monthly, price_cents: 0)
    variant_category = create(:variant_category, link:, title: "Tier")
    create(:variant, variant_category:, name: "Untitled")

    visit("/l/#{link.unique_permalink}")
    expect(page).to_not have_radio_button("Untitled")
    expect(page).to have_radio_button("Membership")
  end

  it "displays the right suggested amount per variant for PWYW products" do
    @product.price_range = "3+"
    @product.customizable_price = true
    @product.save

    variant_category = create(:variant_category, link: @product, title: "type")
    [["default", 0], ["type 1 (test)", 150]].each do |name, price_difference_cents|
      create(:variant, variant_category:, name:, price_difference_cents:)
    end

    visit short_link_url(host: @user.subdomain_with_protocol, id: @product.unique_permalink, option: variant_category.variants[0].external_id)
    expect(page).to(have_field("Name a fair price:", placeholder: "3+"))

    choose "type 1 (test)"
    expect(page).to(have_field("Name a fair price:", placeholder: "4.50+"))

    fill_in "Name a fair price", with: "4"
    click_on "I want this!"

    expect(find_field("Name a fair price")["aria-invalid"]).to eq("true")

    add_to_cart(@product, option: "type 1 (test)", pwyw_price: 5)
  end
end
