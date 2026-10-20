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

describe Purchase, "new-customer offer codes" do
  let(:membership_purchase) { create(:membership_purchase, email: "member@example.com") }
  let(:membership) { membership_purchase.link }
  let(:subscription) { membership_purchase.subscription }
  let(:offer_code) { create(:offer_code, :for_new_customers, user: membership.user, products: [membership], amount_cents: nil, amount_percentage: 100) }
  let(:rejection) { "Sorry, this discount code is only for new customers. Remove it to complete your purchase." }

  before { membership_purchase.update!(offer_code:) }

  it "keeps the code on a renewal of the subscription it was redeemed on" do
    renewal = create(:purchase, link: membership, subscription:, is_original_subscription_purchase: false, email: membership_purchase.email, variant_attributes: membership_purchase.variant_attributes, offer_code:)

    expect(renewal.errors.full_messages).to be_empty
  end

  it "keeps the code when a plan change re-prices that subscription" do
    plan_change = build(:purchase, link: membership, subscription:, is_original_subscription_purchase: true, email: membership_purchase.email, variant_attributes: membership_purchase.variant_attributes, offer_code:)
    plan_change.is_updated_original_subscription_purchase = true
    plan_change.save!

    expect(plan_change.errors.full_messages).to be_empty
  end

  it "keeps a commission deposit's code on its completion purchase" do
    commission_product = create(:commission_product, user: create(:user, created_at: 2.months.ago))
    commission_code = create(:offer_code, :for_new_customers, user: commission_product.user, products: [commission_product], code: "firstcommission", amount_cents: nil, amount_percentage: 100)
    create(:purchase, link: commission_product, email: "client@example.com", offer_code: commission_code)

    completion = create(:purchase, link: commission_product, email: "client@example.com", offer_code: commission_code, is_commission_completion_purchase: true)

    expect(completion.errors.full_messages).to be_empty
  end

  it "rejects a new-customer code first applied during a plan change" do
    other_code = create(:offer_code, :for_new_customers, user: membership.user, products: [membership], code: "welcome", amount_cents: nil, amount_percentage: 100)
    plan_change = build(:purchase, link: membership, subscription:, is_original_subscription_purchase: true, email: membership_purchase.email, variant_attributes: membership_purchase.variant_attributes, offer_code: other_code)
    plan_change.is_updated_original_subscription_purchase = true
    plan_change.save!

    expect(plan_change.errors.full_messages).to eq([rejection])
  end
end

describe Purchase, "renewing a membership bought with a new-customer code" do
  let(:buyer) { create(:user, email: "member.renewal@example.com") }
  let(:membership) { create(:membership_product, price_cents: 1000) }
  let(:offer_code) { create(:offer_code, :for_new_customers, user: membership.user, products: [membership], amount_cents: nil, amount_percentage: 100) }
  let(:original) do
    create(:membership_purchase, link: membership, purchaser: buyer, email: buyer.email, price_cents: 0, offer_code:).tap do
      _1.subscription.update!(user: buyer)
    end
  end

  def renew!
    subscription = original.subscription.reload
    travel_to(subscription.end_time_of_subscription + 1.hour) { subscription.charge! }
    subscription.purchases.where.not(id: original.id).order(:id).last
  end

  it "keeps the discount the buyer got on their first purchase" do
    original.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: true,
                                                  pre_discount_minimum_price_cents: 1000)

    renewal = renew!

    expect(renewal.errors.full_messages).to be_empty
    expect(renewal.offer_code).to eq(offer_code)
    expect(renewal.price_cents).to eq(0)
  end

  it "keeps the discount when the original purchase has no cached discount to reuse" do
    renewal = renew!

    expect(renewal.errors.full_messages).to be_empty
    expect(renewal.offer_code).to eq(offer_code)
    expect(renewal.price_cents).to eq(0)
  end
end

describe Purchase, "new-customers-only codes on a later charge" do
  let(:seller) { create(:named_seller) }
  let(:buyer) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 1_000) }
  let(:offer_code) do
    create(:offer_code, products: [product], new_customers_only: true, amount_cents: nil, amount_percentage: 20)
  end
  let(:subscription) { create(:subscription, link: product, user: buyer) }
  let(:rejection) { "Sorry, this discount code is only for new customers. Remove it to complete your purchase." }

  before do
    create(:purchase, link: product, seller:, purchaser: buyer, subscription:, offer_code:,
                      is_original_subscription_purchase: true, purchase_state: "not_charged",
                      price_cents: product.price_cents)
  end

  # Pricing keeps the discount; checkout's validation is where a returning buyer would be refused.
  def checkout_errors(purchase)
    purchase.send(:validate_offer_code)
    purchase.errors.full_messages
  end

  it "keeps the discount on the buyer's renewal instead of refusing the code that priced their plan" do
    renewal = build(:purchase, link: product, seller:, purchaser: buyer, subscription:,
                               is_original_subscription_purchase: false, offer_code:)

    expect(renewal.send(:resolved_offer_code_discount_for_buyer)).to eq({ type: "percent", percents: 20 })
    expect(checkout_errors(renewal)).to be_empty
  end

  it "keeps the discount on a later installment of the same plan" do
    installment = build(:purchase, link: product, seller:, purchaser: buyer, offer_code:,
                                   is_installment_payment: true, is_original_subscription_purchase: false)

    expect(installment.send(:resolved_offer_code_discount_for_buyer)).to eq({ type: "percent", percents: 20 })
    expect(checkout_errors(installment)).to be_empty
  end

  it "keeps the discount on the release charge of a preorder the buyer already authorized" do
    preorder = create(:preorder, preorder_link: create(:preorder_link, link: product), purchaser: buyer)
    create(:purchase, link: product, seller:, purchaser: buyer, preorder:, is_preorder_authorization: true,
                      purchase_state: "preorder_authorization_successful", price_cents: 1_000)
    charge = build(:purchase, link: product, seller:, purchaser: buyer, offer_code:, preorder:)

    expect(charge.send(:resolved_offer_code_discount_for_buyer)).to eq({ type: "percent", percents: 20 })
    expect(checkout_errors(charge)).to be_empty
  end

  it "still decides the code on the preorder authorization itself" do
    preorder = create(:preorder, preorder_link: create(:preorder_link, link: product), purchaser: buyer)
    authorization = build(:purchase, link: product, seller:, purchaser: buyer, offer_code:, preorder:,
                                     is_preorder_authorization: true)

    expect(checkout_errors(authorization)).to eq([rejection])
  end

  it "still refuses the code when the same buyer starts something new" do
    other_product = create(:product, user: seller, price_cents: 1_000)
    new_purchase = build(:purchase, link: other_product, seller:, purchaser: buyer, offer_code:)

    expect(checkout_errors(new_purchase)).to eq([rejection])
  end

  it "still refuses the code on a first installment" do
    plan_product = create(:product, user: seller, price_cents: 1_000)
    first_installment = build(:purchase, link: plan_product, seller:, purchaser: buyer,
                                         is_installment_payment: true, is_original_subscription_purchase: true,
                                         offer_code:)

    expect(checkout_errors(first_installment)).to eq([rejection])
  end
end
