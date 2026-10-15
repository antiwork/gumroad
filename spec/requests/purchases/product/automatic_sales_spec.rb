# frozen_string_literal: true

require "spec_helper"

describe "Automatic sales on product pages", type: :system, js: true do
  [1, 2].each do |quantity|
    it "keeps the displayed price through checkout for #{quantity} units with a minimum spend" do
      product = create(:product, price_cents: 1000, quantity_enabled: true)
      product.user.offer_codes.create!(code: "sale30", amount_percentage: 30, universal: true, auto_apply: true, sale_label: "Spring sale", minimum_amount_cents: 1500)

      visit "/l/#{product.unique_permalink}"
      fill_in "Quantity", with: quantity
      expect(page).to have_selector("[itemprop='price']", text: quantity == 1 ? "$10" : "$10 $7", exact_text: true, normalize_ws: true)
      if quantity == 1
        expect(page).to have_no_selector("[data-testid='sale-banner']")
      else
        expect(page).to have_selector("[data-testid='sale-banner']", text: "Spring sale")
      end
      click_on "I want this!"
      check_out(product)

      expect(Purchase.last.price_cents).to eq(quantity == 1 ? 1000 : 1400)
      expect(Purchase.last.quantity).to eq(quantity)
    end
  end

  it "shows membership sale terms and expires the banner before a tier is selected" do
    product = create(:membership_product_with_preset_tiered_pricing)
    product.user.offer_codes.create!(code: "member30", amount_percentage: 30, universal: true, auto_apply: true, sale_label: "Member sale", valid_at: 1.day.ago, expires_at: 30.days.from_now)

    visit "/l/#{product.unique_permalink}"

    expect(page).to have_selector("[data-testid='sale-banner']", text: "Member sale")
    expect(page).to have_selector("[role='status'] time")
    expect(page).to have_no_selector("[data-testid='sale-banner']")
    expect(page).to have_selector("[role='status']", text: "Sorry, the discount code you wish to use is inactive.")
  end
end
