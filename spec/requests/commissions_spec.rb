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
end
