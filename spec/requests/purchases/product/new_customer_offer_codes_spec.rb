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

  # Checkout decides on the email the visitor enters, so the page doesn't refuse someone it can't identify.
  it "offers the code to a visitor who is not signed in" do
    visit "#{product.long_url}/welcome20"

    expect(page).to have_selector("[role='status']", text: "20% off will be applied at checkout")
    expect(page).to have_selector("[itemprop='price']", text: "$30 $24", visible: false)
  end

  context "when a guest checks out" do
    let(:earlier_product) { create(:product, user: seller, price_cents: 2000, name: "Starter Pack") }
    let!(:free_code) do
      create(:offer_code, :for_new_customers, user: seller, products: [product], amount_cents: nil, amount_percentage: 100, code: "firstorder")
    end

    it "completes a first purchase from the store with the code" do
      visit "#{product.long_url}/firstorder"
      add_to_cart(product, offer_code: free_code)
      check_out(product, email: "first.time@example.com", is_free: true)

      expect(Purchase.last).to have_attributes(offer_code: free_code, price_cents: 0, email: "first.time@example.com")
    end

    it "rejects an email that already bought from the store and lets the buyer remove the code" do
      create(:purchase, link: earlier_product, purchaser: nil, email: "Repeat.Buyer@Example.com")

      visit "#{product.long_url}/firstorder"
      add_to_cart(product, offer_code: free_code)
      check_out(product, email: "repeat.buyer@example.com", is_free: true,
                         error: "Sorry, this discount code is only for new customers. Remove it to complete your purchase.")

      wait_until_true(sleep_interval: CheckoutPresenter::CART_SAVE_DEBOUNCE_DURATION_IN_SECONDS) { Cart.alive.where(email: "repeat.buyer@example.com").exists? }
      visit checkout_path
      expect(page).to have_text("Total US$0", normalize_ws: true)
      find("[aria-label='Discount code']", text: "firstorder").click
      expect(page).not_to have_selector("[aria-label='Discount code']", text: "firstorder")
      expect(page).to have_text("Total US$30", normalize_ws: true)
    end
  end
end
