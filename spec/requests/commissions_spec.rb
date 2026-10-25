# frozen_string_literal: true

require "spec_helper"

describe "Commissions", type: :system, js: true do
  let(:seller) { create(:user, :eligible_for_service_products) }
  let(:commission1) { create(:product, user: seller, name: "Commission 1", native_type: Link::NATIVE_TYPE_COMMISSION, price_cents: 200) }
  let(:commission2) { create(:product, user: seller, name: "Commission 2", native_type: Link::NATIVE_TYPE_COMMISSION, price_cents: 1000) }
  let(:product) { create(:product, user: seller, name: "Product", price_cents: 100) }

  before do
    create(:offer_code, user: seller, code: "commission", amount_cents: 500, products: [commission2])
  end

  it "shows notices explaining the commission" do
    visit commission1.long_url

    expect(page).to have_status(text: "Secure your order with a 50% deposit today; the remaining balance will be charged upon completion.")

    click_on "I want this!"

    expect(page).to have_text("Payment today US$1", normalize_ws: true)
    expect(page).to have_text("Payment after completion US$1", normalize_ws: true)

    visit "#{commission2.long_url}/commission"
    click_on "I want this!"

    expect(page).to have_text("Payment today US$3.50", normalize_ws: true)
    expect(page).to have_text("Payment after completion US$3.50", normalize_ws: true)

    visit product.long_url
    click_on "I want this!"

    expect(page).to have_text("Payment today US$4.50", normalize_ws: true)
    expect(page).to have_text("Payment after completion US$3.50", normalize_ws: true)
  end

  it "shows the balance a once-per-cart discount leaves after the rounded deposit" do
    commission = create(:product, user: seller, name: "Commission 3", native_type: Link::NATIVE_TYPE_COMMISSION, price_cents: 20_01)
    create(:offer_code, user: seller, code: "oncepercart", amount_cents: 5_00, once_per_cart: true, products: [commission])

    visit "#{commission.long_url}/oncepercart"
    click_on "I want this!"

    expect(page).to have_text("Total US$15.01", normalize_ws: true)
    expect(page).to have_text("Payment today US$7.51", normalize_ws: true)
    expect(page).to have_text("Payment after completion US$7.50", normalize_ws: true)
  end
end
