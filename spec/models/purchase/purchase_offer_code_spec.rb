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

  it "locks a capped cart discount for an updated original subscription purchase" do
    product = create(:membership_product)
    offer_code = create(
      :offer_code,
      products: [product],
      amount_cents: 100,
      once_per_cart: true,
      max_purchase_count: 1
    )
    purchase = build(
      :purchase_in_progress,
      link: product,
      seller: product.user,
      offer_code:,
      is_original_subscription_purchase: true,
      is_updated_original_subscription_purchase: true
    )
    purchase.build_purchase_offer_code_discount(
      offer_code:,
      offer_code_amount: 100,
      offer_code_is_percent: false,
      once_per_cart: true,
      once_per_cart_allocation_id: SecureRandom.uuid,
      pre_discount_minimum_price_cents: product.price_cents
    )
    purchase.skip_preparing_for_charge = true

    expect(offer_code).to receive(:with_lock).and_call_original

    purchase.prepare_for_charge!
  end
end
