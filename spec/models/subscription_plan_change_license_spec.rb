# frozen_string_literal: true

require "spec_helper"

describe Subscription, "#update_current_plan! license" do
  it "moves the license onto the new original purchase" do
    product = create(:membership_product)
    other_tier = create(:variant, variant_category: product.tier_category, name: "Other")
    purchase = create(:membership_purchase, link: product, tier: other_tier)
    license = create(:license, link: product, purchase:)
    subscription = purchase.subscription

    new_purchase = subscription.update_current_plan!(new_variants: [product.tiers.first], new_price: subscription.price, skip_preparing_for_charge: true)

    expect(license.reload.purchase_id).to eq(new_purchase.id)
    expect(subscription.reload.original_purchase.license).to eq(license)
  end
end
