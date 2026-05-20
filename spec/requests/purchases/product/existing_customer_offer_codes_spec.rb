# frozen_string_literal: true

require("spec_helper")

describe("Ownership-based offer codes from product page", type: :system, js: true) do
  let(:seller) { create(:user) }
  let(:ownership_product) { create(:product, user: seller, price_cents: 2000, name: "Starter Pack") }
  let(:target_product) { create(:product, user: seller, price_cents: 3000, name: "Pro Membership") }

  def expect_full_price
    expect(page).to have_content(target_product.name)
    expect(page).to have_selector("[itemprop='price']", text: "$30", visible: false)
  end

  def expect_discount_banner(percent:, discounted_price:)
    expect(page).to have_selector("[role='status']", text: "#{percent}% off will be applied at checkout")
    expect(page).to have_selector("[itemprop='price']", text: "$30 $#{discounted_price}", visible: false)
  end

  context "with a Limit-to-existing-customers gate" do
    it "rejects the URL-applied code when the visitor isn't an existing customer" do
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
      expect_full_price
    end

    it "applies a flat existing-customer discount once the buyer owns the required product" do
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

      expect_discount_banner(percent: 20, discounted_price: 24)
    end

    it "applies the matching tier percentage when the buyer's ownership duration crosses a threshold" do
      create(:tiered_offer_code, :for_existing_customers,
             user: seller,
             products: [target_product],
             ownership_products: [ownership_product],
             code: "renewy2")
      buyer = create(:user)
      create(:purchase, purchaser: buyer, link: ownership_product, seller:, price_cents: 0, created_at: 14.months.ago)

      login_as buyer
      visit "#{target_product.long_url}/renewy2"

      expect_discount_banner(percent: 50, discounted_price: 15)
    end
  end

  context "with a standalone Tier-discount-by-ownership-duration toggle" do
    it "applies the matching tier percentage based on the buyer's tenure on the same product" do
      create(:tiered_offer_code, user: seller, products: [target_product], code: "renewal50")
      buyer = create(:user)
      create(:purchase, purchaser: buyer, link: target_product, seller:, price_cents: 0, created_at: 14.months.ago)

      login_as buyer
      visit "#{target_product.long_url}/renewal50"

      expect_discount_banner(percent: 50, discounted_price: 15)
    end

    it "shows no discount banner for a first-time buyer" do
      create(:tiered_offer_code, user: seller, products: [target_product], code: "renewal50")

      visit "#{target_product.long_url}/renewal50"

      expect_full_price
      expect(page).not_to have_selector("[role='status']", text: "off will be applied at checkout")
    end

    it "does not leak tier tenure across products in a multi-product code" do
      other_product = create(:product, user: seller, price_cents: 4000, name: "Other Membership")
      create(:tiered_offer_code, user: seller, products: [target_product, other_product], code: "tenure50")
      buyer = create(:user)
      create(:purchase, purchaser: buyer, link: other_product, seller:, price_cents: 0, created_at: 14.months.ago)

      login_as buyer
      visit "#{target_product.long_url}/tenure50"

      expect_full_price
      expect(page).not_to have_selector("[role='status']", text: "off will be applied at checkout")
    end
  end
end
