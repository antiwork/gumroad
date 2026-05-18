# frozen_string_literal: true

require("spec_helper")

describe("Existing-customer offer codes from product page", type: :system, js: true) do
  let(:seller) { create(:user) }
  let(:ownership_product) { create(:product, user: seller, price_cents: 2000, name: "Starter Pack") }
  let(:target_product) { create(:product, user: seller, price_cents: 3000, name: "Pro Membership") }

  it "rejects the URL-applied code on the product page when the visitor isn't an existing customer" do
    create(:offer_code,
           user: seller,
           products: [target_product],
           ownership_products: [ownership_product],
           existing_customers_only: true,
           amount_cents: nil,
           amount_percentage: 20,
           code: "loyal20")

    visit "#{target_product.long_url}/loyal20"

    expect(page).to have_selector("[role='status']", text: "Sorry, this discount code is only for existing customers.")
    expect(page).to have_selector("[itemprop='price']", text: "$30", visible: false)
  end

  it "applies a flat existing-customer discount on the product page once the buyer owns the required product" do
    create(:offer_code,
           user: seller,
           products: [target_product],
           ownership_products: [ownership_product],
           existing_customers_only: true,
           amount_cents: nil,
           amount_percentage: 20,
           code: "loyal20")
    buyer = create(:user)
    create(:purchase, purchaser: buyer, link: ownership_product, seller:, price_cents: 0)

    login_as buyer
    visit "#{target_product.long_url}/loyal20"

    expect(page).to have_selector("[role='status']", text: "20% off will be applied at checkout")
    expect(page).to have_selector("[itemprop='price']", text: "$30 $24", visible: false)
  end

  it "applies the matching tier percentage when the buyer's ownership duration crosses a threshold" do
    create(:tiered_offer_code,
           user: seller,
           products: [target_product],
           ownership_products: [ownership_product],
           code: "renewy2")
    buyer = create(:user)
    create(:purchase, purchaser: buyer, link: ownership_product, seller:, price_cents: 0, created_at: 14.months.ago)

    login_as buyer
    visit "#{target_product.long_url}/renewy2"

    expect(page).to have_selector("[role='status']", text: "50% off will be applied at checkout")
    expect(page).to have_selector("[itemprop='price']", text: "$30 $15", visible: false)
  end
end
