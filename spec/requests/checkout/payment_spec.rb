# frozen_string_literal: true

require "spec_helper"

describe "Checkout payment", :js, type: :system do
  before do
    @product = create(:product, price_cents: 1000)
  end

  it "shows native, braintree, or no paypal button depending on availability" do
    create(:merchant_account_paypal, user: @product.user, charge_processor_merchant_id: "CJS32DZ7NDN5L", currency: "gbp")
    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    select_tab "PayPal"
    expect(page).to have_selector("iframe[title=PayPal]")

    product2 = create(:product, price_cents: 1000)
    visit "/l/#{product2.unique_permalink}"
    add_to_cart(product2)
    select_tab "PayPal"
    expect(page).to_not have_selector("iframe[title=PayPal]")
    expect(page).to have_button "Pay"

    product3 = create(:product, price_cents: 1000)
    product3.user.update!(disable_paypal_sales: true)
    visit "/l/#{product3.unique_permalink}"
    add_to_cart(product3)
    expect(page).to_not have_tab_button "PayPal"
  end
end
