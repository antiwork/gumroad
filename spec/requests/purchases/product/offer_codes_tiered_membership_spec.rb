# frozen_string_literal: true

require("spec_helper")

describe("Offer-code usage from product page for tiered membership", type: :system, js: true) do
  let(:product) { create(:membership_product_with_preset_tiered_pricing, user: create(:user, display_offer_code_field: true)) }
  let!(:offer_code) { create(:offer_code, products: [product], amount_cents: 4_00) }

  it "allows the user to redeem an offer code" do
    visit "/l/#{product.unique_permalink}"

    add_to_cart(product, option: "Second Tier")

    fill_in "Discount code", with: offer_code.code
    click_on "Apply"
    wait_for_ajax

    expect(page).to have_text("Total US$1", normalize_ws: true)

    check_out(product)
  end

  context "with one tier" do
    before do
      tier_category = product.tier_category
      @first_tier = tier_category.variants.first
      @first_tier.save_recurring_prices!("monthly" => { enabled: true, price: 2 }, "yearly" => { enabled: true, price: 10 })
      @second_tier = tier_category.variants.last
      @second_tier.mark_deleted
    end

    it "displays recurrences as options, shows original and discounted price for each" do
      visit URI::DEFAULT_PARSER.escape("/l/#{product.unique_permalink}/#{offer_code.code}")

      expect(page).to have_selector("[itemprop='price']", text: "$2 $0 a month", visible: false)

      add_to_cart(product, recurrence: "Yearly", offer_code:, option: @first_tier.name)

      check_out(product)

      Timeout.timeout(Capybara.default_max_wait_time) do
        loop until Purchase.successful.count == 1
      end

      purchase = Purchase.successful.last
      expect(purchase.subscription.price).to eq product.prices.find_by!(recurrence: BasePrice::Recurrence::YEARLY)
      expect(purchase.variant_attributes.map(&:id)).to eq [@first_tier.id]
    end
  end

  context "with a free trial" do
    it "doesn't require payment info for products that are discounted to free" do
      product.update!(free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: "month")
      visit "#{product.long_url}/#{offer_code.code}"
      add_to_cart(product, option: "First Tier", offer_code:)
      expect(page).to have_text("Subtotal US$0", normalize_ws: true)
      expect(page).to have_text("Total US$0", normalize_ws: true)
      expect(page).to_not have_selector(:fieldset, "Card information")
      check_out(product, is_free: true)
    end
  end
end
