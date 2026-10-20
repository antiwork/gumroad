# frozen_string_literal: true

require("spec_helper")

describe("New-customer-only offer codes from product page", type: :system, js: true) do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 3000, name: "Pro Membership") }
  let!(:offer_code) do
    create(:offer_code,
           user: seller,
           products: [product],
           new_customers_only: true,
           amount_cents: nil,
           amount_percentage: 20,
           currency_type: nil,
           code: "welcome20")
  end

  def expect_full_price
    expect(page).to have_content(product.name)
    expect(page).to have_selector("[itemprop='price']", text: "$30", visible: false)
  end

  it "applies the discount for a signed-in buyer with no purchase history" do
    login_as create(:user)
    visit "#{product.long_url}/welcome20"

    expect(page).to have_selector("[role='status']", text: "20% off will be applied at checkout")
    expect(page).to have_selector("[itemprop='price']", text: "$30 $24", visible: false)
  end

  it "rejects the code for a signed-in buyer who has bought from the store before" do
    buyer = create(:user)
    other_product = create(:product, user: seller, price_cents: 5_00)
    create(:purchase, purchaser: buyer, link: other_product, seller:, price_cents: 0)

    login_as buyer
    visit "#{product.long_url}/welcome20"

    expect(page).to have_selector("[role='status']", text: "Sorry, this discount code is only for new customers.")
    expect_full_price
  end

  it "rejects the code for a visitor who is not signed in" do
    visit "#{product.long_url}/welcome20"

    expect(page).to have_selector("[role='status']", text: "Sorry, this discount code is only for new customers.")
    expect_full_price
  end
end
