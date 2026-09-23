# frozen_string_literal: true

require "spec_helper"

describe Purchase, "offer-code capacity" do
  it "rechecks a capped cart discount without relying on discount_code" do
    product = create(:product)
    offer_code = create(
      :offer_code,
      products: [product],
      amount_cents: 100,
      once_per_cart: true,
      max_purchase_count: 1
    )
    allocation_id = SecureRandom.uuid
    reserved_purchase = create(
      :purchase_in_progress,
      link: product,
      seller: product.user,
      offer_code:,
      purchaser: nil
    )
    reserved_purchase.create_purchase_offer_code_discount!(
      offer_code:,
      offer_code_amount: 100,
      offer_code_is_percent: false,
      once_per_cart: true,
      once_per_cart_allocation_id: allocation_id,
      pre_discount_minimum_price_cents: product.price_cents
    )

    purchase = build(:purchase_in_progress, link: product, seller: product.user, offer_code:)
    purchase.build_purchase_offer_code_discount(
      offer_code:,
      offer_code_amount: 100,
      offer_code_is_percent: false,
      once_per_cart: true,
      once_per_cart_allocation_id: SecureRandom.uuid,
      pre_discount_minimum_price_cents: product.price_cents
    )
    purchase.skip_preparing_for_charge = true

    expect(purchase.discount_code).to be_nil
    expect { purchase.prepare_for_charge! }.not_to raise_error
    expect(purchase).not_to be_persisted
    expect(purchase.error_code).to eq(PurchaseErrorCode::OFFER_CODE_SOLD_OUT)
  end

  it "excludes its own once-per-cart allocation when picking the usage error" do
    product = create(:product)
    offer_code = create(
      :offer_code,
      products: [product],
      amount_cents: 100,
      once_per_cart: true,
      max_purchase_count: 1
    )
    completed_purchase = create(:purchase, link: product, seller: product.user, offer_code:, purchaser: nil)
    completed_purchase.create_purchase_offer_code_discount!(
      offer_code:,
      offer_code_amount: 100,
      offer_code_is_percent: false,
      once_per_cart: true,
      once_per_cart_allocation_id: SecureRandom.uuid,
      pre_discount_minimum_price_cents: product.price_cents
    )

    allocation_id = SecureRandom.uuid
    purchase = build(:purchase_in_progress, link: product, seller: product.user, offer_code:)
    purchase.build_purchase_offer_code_discount(
      offer_code:,
      offer_code_amount: 100,
      offer_code_is_percent: false,
      once_per_cart: true,
      once_per_cart_allocation_id: allocation_id,
      pre_discount_minimum_price_cents: product.price_cents
    )

    # The error branch must read capacity with the same exclusions as the
    # availability check, or the two usage messages can disagree.
    expect(offer_code).to receive(:quantity_left)
      .with(hash_including(excluding_once_per_cart_allocation_ids: [allocation_id]))
      .and_call_original

    purchase.send(:add_offer_code_usage_error, offer_code)

    expect(purchase.error_code).to eq(PurchaseErrorCode::OFFER_CODE_SOLD_OUT)
  end

  it "sizes a temporary-discount mandate from the saved PWYW total" do
    product = create(:membership_product, price_cents: 10_00, customizable_price: true)
    offer_code = create(:offer_code, products: [product], amount_cents: 5_00, once_per_cart: true)
    purchase = build(
      :purchase_in_progress,
      link: product,
      seller: product.user,
      displayed_price_cents: 15_00,
      total_transaction_cents: 15_00
    )
    purchase.build_purchase_offer_code_discount(
      offer_code:,
      offer_code_amount: 5_00,
      offer_code_is_percent: false,
      once_per_cart: true,
      pre_discount_minimum_price_cents: 10_00,
      pre_discount_displayed_price_cents: 20_00,
      duration_in_months: 1
    )

    expect(purchase.mandate_maximum_amount_cents).to eq(20_00)
  end

  it "does not reserve capacity for an updated original subscription purchase" do
    product = create(:membership_product)
    offer_code = create(
      :offer_code,
      products: [product],
      amount_cents: 100,
      once_per_cart: true,
      max_purchase_count: 1
    )
    # The subscription's original purchase already consumed the use, so a plan
    # update must go through even when the cap is fully spent.
    offer_code.update_column(:max_purchase_count, 0)
    purchase = build(
      :purchase_in_progress,
      link: product,
      seller: product.user,
      offer_code:,
      is_original_subscription_purchase: true,
      is_updated_original_subscription_purchase: true
    )
    purchase.variant_attributes << product.tiers.first
    purchase.build_purchase_offer_code_discount(
      offer_code:,
      offer_code_amount: 100,
      offer_code_is_percent: false,
      once_per_cart: true,
      once_per_cart_allocation_id: SecureRandom.uuid,
      pre_discount_minimum_price_cents: product.price_cents
    )
    purchase.skip_preparing_for_charge = true

    expect(offer_code).not_to receive(:with_lock)

    purchase.prepare_for_charge!

    expect(purchase.error_code).to be_nil
    expect(purchase).to be_persisted
  end

  it "rejects a sibling version and still discounts the scoped one" do
    product = create(:product, price_cents: 2_000)
    category = create(:variant_category, link: product)
    tier = create(:variant, variant_category: category, name: "Basic")
    sibling = create(:variant, variant_category: category, name: "Pro")
    expect(tier.link_id).to be_nil
    offer_code = create(:offer_code, user: product.user, products: [product], amount_cents: 100, variants: [tier])

    rejected = build(:purchase_in_progress, link: product, seller: product.user, offer_code:, discount_code: offer_code.code)
    rejected.variant_attributes << sibling
    rejected.send(:validate_offer_code)

    expect(rejected.errors.full_messages).to include("This code does not apply to the selected option.")
    expect(rejected.send(:offer_amount_off, product.price_cents)).to eq(0)

    allowed = build(:purchase_in_progress, link: product, seller: product.user, offer_code:, discount_code: offer_code.code)
    allowed.variant_attributes << tier
    allowed.send(:validate_offer_code)

    expect(allowed.errors.full_messages).not_to include("This code does not apply to the selected option.")
    expect(allowed.send(:offer_amount_off, product.price_cents)).to eq(100)
  end

  it "rejects a remaining option after the scoped option is deleted" do
    product = create(:product, price_cents: 2_000)
    category = create(:variant_category, link: product)
    tier = create(:variant, variant_category: category, name: "Basic")
    sibling = create(:variant, variant_category: category, name: "Pro")
    offer_code = create(:offer_code, user: product.user, products: [product], amount_cents: 100, variants: [tier])
    tier.mark_deleted!

    purchase = build(:purchase_in_progress, link: product, seller: product.user, offer_code:, discount_code: offer_code.code)
    purchase.variant_attributes << sibling
    purchase.send(:validate_offer_code)

    expect(purchase.errors.full_messages).to include("This code does not apply to the selected option.")
    expect(purchase.send(:offer_amount_off, product.price_cents)).to eq(0)
  end

  it "rejects a line that carries an unscoped sibling next to the scoped option" do
    product = create(:product, price_cents: 2_000)
    category = create(:variant_category, link: product)
    tier = create(:variant, variant_category: category, name: "Basic")
    sibling = create(:variant, variant_category: category, name: "Pro")
    offer_code = create(:offer_code, user: product.user, products: [product], amount_cents: 100, variants: [tier])

    purchase = build(:purchase_in_progress, link: product, seller: product.user, offer_code:, discount_code: offer_code.code)
    purchase.variant_attributes << tier
    purchase.variant_attributes << sibling
    purchase.send(:validate_offer_code)

    expect(purchase.errors.full_messages).to include("This code does not apply to the selected option.")
    expect(purchase.send(:offer_amount_off, product.price_cents)).to eq(0)
  end

  it "still discounts a scoped option when the product has another category the code ignores" do
    product = create(:product, price_cents: 2_000)
    license_category = create(:variant_category, link: product, title: "License")
    tier = create(:variant, variant_category: license_category, name: "Basic")
    format_category = create(:variant_category, link: product, title: "Format")
    format = create(:variant, variant_category: format_category, name: "PDF")
    offer_code = create(:offer_code, user: product.user, products: [product], amount_cents: 100, variants: [tier])

    purchase = build(:purchase_in_progress, link: product, seller: product.user, offer_code:, discount_code: offer_code.code)
    purchase.variant_attributes << tier
    purchase.variant_attributes << format
    purchase.send(:validate_offer_code)

    expect(purchase.errors.full_messages).not_to include("This code does not apply to the selected option.")
    expect(purchase.send(:offer_amount_off, product.price_cents)).to eq(100)
  end

  it "keeps a cached discount off an option the persisted code never covered" do
    product = create(:product, price_cents: 2_000)
    category = create(:variant_category, link: product)
    tier = create(:variant, variant_category: category, name: "Basic")
    sibling = create(:variant, variant_category: category, name: "Pro")
    offer_code = create(:offer_code, user: product.user, products: [product], amount_cents: 100, variants: [tier])

    purchase = build(:purchase_in_progress, link: product, seller: product.user, offer_code:)
    purchase.variant_attributes << sibling
    purchase.build_purchase_offer_code_discount(offer_code:, offer_code_amount: 100, offer_code_is_percent: false, pre_discount_minimum_price_cents: 2_000)

    expect(purchase.send(:offer_amount_off, product.price_cents)).to eq(0)

    purchase.variant_attributes.clear
    purchase.variant_attributes << tier

    expect(purchase.send(:offer_amount_off, product.price_cents)).to eq(100)
  end
end
