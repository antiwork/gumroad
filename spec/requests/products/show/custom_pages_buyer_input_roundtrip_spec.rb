# frozen_string_literal: true

require "spec_helper"

# End-to-end (real browser, Capybara) coverage of the buyer-input checkout-key
# round trip called for in #5406's acceptance criteria:
#
#   > Tests cover the checkout key round trip: variant, option, quantity,
#   > price, recurrence.
#
# Custom landing pages (#5063 / #5406) hand buyer-input state to checkout purely
# through the URL keys the `?wanted=true` flow already accepts
# (variant / option / quantity / price / recurrence). The producer side — baking
# those keys into the `?wanted=true` href — is covered by
# Pages::BuyButtonParams / Pages::Interpolator. A companion controller spec
# (links_controller_spec.rb) pins the redirect URL shape.
#
# What was still missing, and what these specs add, is proof of the FULL round
# trip in a real browser: a buyer who lands on a `?wanted=true` prefill URL
# actually sees the prefilled selection applied AND can complete the purchase,
# with the resulting Purchase carrying the right variant / quantity / price /
# recurrence. These also pin the fail-open guarantee the custom-HTML wrapper
# depends on — a page that prefills only *some* keys (or none, or an invalid
# value) must still resolve to a working checkout, never an error or a forced
# selection.
describe("Custom pages buyer-input round trip", type: :system, js: true) do
  it "round-trips a variant prefill: buyer lands pre-selected and the purchase records that variant + its price" do
    product = create(:product_with_digital_versions_with_price_difference_cents, price_cents: 100)
    variant = product.alive_variants.find_by(name: "Untitled 2") # +200 cents

    visit "#{product.long_url}?wanted=true&variant=Untitled 2"

    # Buyer is dropped straight onto checkout with the variant already chosen.
    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    within_cart_item product.name do
      expect(page).to have_text("Version: Untitled 2")
      expect(page).to have_text("$3") # base 100 + price_difference 200 = 300 cents
    end

    check_out(product)

    purchase = product.sales.successful.last
    expect(purchase.variant_attributes).to eq([variant])
    expect(purchase.price_cents).to eq(300)
  end

  it "round-trips an option-id prefill the same way a variant name does" do
    product = create(:product_with_digital_versions_with_price_difference_cents, price_cents: 100)
    variant = product.alive_variants.find_by(name: "Untitled 1") # +100 cents

    visit "#{product.long_url}?wanted=true&option=#{variant.external_id}"

    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    within_cart_item product.name do
      expect(page).to have_text("Version: Untitled 1")
    end

    check_out(product)

    purchase = product.sales.successful.last
    expect(purchase.variant_attributes).to eq([variant])
    expect(purchase.price_cents).to eq(200)
  end

  it "round-trips a quantity prefill all the way to the recorded purchase" do
    product = create(:product, quantity_enabled: true, price_cents: 100)

    visit "#{product.long_url}?wanted=true&quantity=3"

    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    within_cart_item product.name do
      expect(page).to have_text("Qty: 3")
    end

    check_out(product)

    purchase = product.sales.successful.last
    expect(purchase.quantity).to eq(3)
    expect(purchase.price_cents).to eq(300)
  end

  it "round-trips a PWYW price prefill (major units -> cents) to the recorded purchase" do
    product = create(:product, customizable_price: true, price_cents: 100)

    visit "#{product.long_url}?wanted=true&price=9.99"

    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    within_cart_item product.name do
      expect(page).to have_text("$9.99")
    end

    check_out(product)

    expect(product.sales.successful.last.price_cents).to eq(999)
  end

  it "round-trips a recurrence prefill on a membership product and records the subscription recurrence" do
    product = create(:membership_product_with_preset_tiered_pricing, subscription_duration: :monthly)
    create(:price, link: product, recurrence: "yearly", price_cents: 1200)
    tier = product.tiers.find_by(name: "Second Tier")

    visit "#{product.long_url}?wanted=true&recurrence=monthly&option=#{tier.external_id}"

    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    within_cart_item product.name do
      expect(page).to have_text("Tier: Second Tier")
      expect(page).to have_text("Monthly")
    end

    check_out(product)

    subscription = product.subscriptions.last
    expect(subscription).to be_present
    expect(subscription.recurrence).to eq("monthly")
    expect(subscription.original_purchase.variant_attributes).to eq([tier])
  end

  it "round-trips a full multi-key prefill (variant + quantity) in one URL" do
    product = create(:product_with_digital_versions_with_price_difference_cents, price_cents: 100, quantity_enabled: true)
    variant = product.alive_variants.find_by(name: "Untitled 2") # +200 cents

    visit "#{product.long_url}?wanted=true&variant=Untitled 2&quantity=2"

    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    within_cart_item product.name do
      expect(page).to have_text("Version: Untitled 2")
      expect(page).to have_text("Qty: 2")
    end

    check_out(product)

    purchase = product.sales.successful.last
    expect(purchase.variant_attributes).to eq([variant])
    expect(purchase.quantity).to eq(2)
    expect(purchase.price_cents).to eq(600) # (100 + 200) * 2
  end

  # --- Fail-open guarantees the custom-HTML wrapper depends on ---------------

  it "fails open when NO selection is prefilled: buyer still reaches a working checkout" do
    product = create(:product_with_digital_versions_with_price_difference_cents, price_cents: 100)
    default_variant = product.alive_variants.first # first in-stock option

    visit "#{product.long_url}?wanted=true"

    # No variant/quantity/price in the URL — the flow still lands on checkout
    # with the product's defaults, never an error or a "please select" block.
    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    expect(page).to have_cart_item(product.name)

    check_out(product)

    # cart_item defaulted to the first in-stock option.
    expect(product.sales.successful.last.variant_attributes).to eq([default_variant])
  end

  it "fails open on a partial prefill: variant set, quantity/price omitted resolve to defaults" do
    product = create(:product_with_digital_versions_with_price_difference_cents, price_cents: 100, quantity_enabled: true)
    variant = product.alive_variants.find_by(name: "Untitled 1") # +100 cents

    visit "#{product.long_url}?wanted=true&variant=Untitled 1"

    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    within_cart_item product.name do
      expect(page).to have_text("Version: Untitled 1")
      expect(page).to have_text("Qty: 1") # omitted quantity -> default 1
    end

    check_out(product)

    purchase = product.sales.successful.last
    expect(purchase.variant_attributes).to eq([variant])
    expect(purchase.quantity).to eq(1)
    expect(purchase.price_cents).to eq(200) # base 100 + variant 100, default qty 1
  end

  it "fails open on an unknown variant name: it is dropped and checkout proceeds with the default option" do
    product = create(:product_with_digital_versions_with_price_difference_cents, price_cents: 100)
    default_variant = product.alive_variants.first

    visit "#{product.long_url}?wanted=true&variant=Does Not Exist"

    # Unknown name doesn't resolve, but the flow still fails open to a working
    # checkout with the default (first in-stock) option rather than erroring.
    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    expect(page).to have_cart_item(product.name)

    check_out(product)

    expect(product.sales.successful.last.variant_attributes).to eq([default_variant])
  end
end
