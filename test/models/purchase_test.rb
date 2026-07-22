# frozen_string_literal: true

require "test_helper"
# StripeMerchantAccountHelper lives under spec/support and mirrors the
# :merchant_account_stripe factory's HTTP-backed account creation. It has no
# RSpec load-time dependency (RSpec is only referenced inside a retry branch the
# recorded cassettes never hit), so require it directly for create_merchant_account_stripe.
require Rails.root.join("spec", "support", "stripe_merchant_account_helper")

# Ported from spec/models/purchase_spec.rb (#3 in the #5801 factory-time ranking),
# the largest file in the top-20. Purchase is exercised through model logic — scopes,
# validations, fees, lifecycle, charge processing. HTTP-touching paths
# (Stripe/PayPal/Braintree) replay the existing RSpec cassettes via the VCR bridge
# (#5938), reusing the create_credit_card/build_chargeable helpers the subscription
# port landed. The RSpec file nests describe/context/it; this suite uses flat
# `test "..."` methods with per-section setup helpers, matching subscription_test.
class PurchaseTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include CurrencyHelper # get_usd_cents, used by the currency-conversion shipping case

  # Mirrors purchase_spec's file-level `let(:ip_address)`.
  IP_ADDRESS = "24.7.90.214"

  setup do
    ensure_gumroad_merchant_accounts
    # purchase_spec treats every product as Discover-recommendable.
    Link.any_instance.stubs(:recommendable?).returns(true)
    # The fixtures suite seeds one `successful_purchase` row (test/fixtures/purchases.yml).
    # RSpec ran on a truncated table, so absolute scope assertions (match_array / eq []) here
    # would otherwise pick up that extra row. Remove it (rolled back with the test transaction).
    Purchase.where(id: purchases(:successful_purchase).id).delete_all
  end

  teardown do
    # Flipper state is process-global and not rolled back with the test transaction, so a
    # feature turned on by the attach_credit_card "enabled" cases would leak into the "not
    # called" cases. Reset it to match RSpec's per-example Flipper state.
    Feature.deactivate(:attach_credit_card_to_purchaser)
    # "new flat fee / on Gumroad day" writes RedisKey.gumroad_day_date; Redis isn't rolled
    # back between tests. Clear it so a leaked Gumroad-day date doesn't waive the fee later.
    $redis.del(RedisKey.gumroad_day_date)
  end

  # =========================== from part 1 ===========================
  test "scopes in_progress returns in_progress purchases" do
    in_progress_purchase = create_purchase(purchase_state: "in_progress")
    create_purchase(purchase_state: "successful")
    assert_includes Purchase.in_progress, in_progress_purchase
  end

  test "scopes in_progress does not return failed purchases" do
    create_purchase(purchase_state: "in_progress")
    successful_purchase = create_purchase(purchase_state: "successful")
    assert_not_includes Purchase.in_progress, successful_purchase
  end

  # --- payment_settling ---
  test "scopes payment_settling returns in-progress purchases whose payment the processor has confirmed" do
    settling = create_purchase(purchase_state: "in_progress", stripe_status: "processing")
    assert_includes Purchase.payment_settling, settling
  end

  test "scopes payment_settling does not return abandoned attempts, which never receive a processor confirmation" do
    abandoned = create_purchase(purchase_state: "in_progress", stripe_status: nil)
    assert_not_includes Purchase.payment_settling, abandoned
  end

  test "scopes payment_settling does not return purchases that reached a terminal state, even though stripe_status remains set" do
    failed = create_purchase(purchase_state: "failed", stripe_status: "payment_intent.payment_failed")
    successful = create_purchase(purchase_state: "successful", stripe_status: "charge.succeeded")
    assert_not_includes Purchase.payment_settling, failed
    assert_not_includes Purchase.payment_settling, successful
  end

  # --- successful ---
  test "scopes successful returns successful purchases" do
    successful_purchase = create_purchase(purchase_state: "successful")
    assert_includes Purchase.successful, successful_purchase
  end

  test "scopes successful does not return failed purchases" do
    failed_purchase = create_purchase(purchase_state: "failed")
    assert_not_includes Purchase.successful, failed_purchase
  end

  # --- .not_successful ---
  test "scopes .not_successful returns only unsuccessful purchases" do
    successful_purchase = create_purchase(purchase_state: "successful")
    failed_purchase = create_purchase(purchase_state: "failed")
    assert_includes Purchase.not_successful, failed_purchase
    assert_not_includes Purchase.not_successful, successful_purchase
  end

  # --- failed ---
  test "scopes failed does not returns successful purchases" do
    successful_purchase = create_purchase(purchase_state: "successful")
    assert_not_includes Purchase.failed, successful_purchase
  end

  test "scopes failed does return failed purchases" do
    failed_purchase = create_purchase(purchase_state: "failed")
    assert_includes Purchase.failed, failed_purchase
  end

  # --- stripe_failed ---
  test "scopes stripe_failed returns failed purchases with non-blank stripe fingerprint" do
    failed_with_fingerprint = create_purchase(stripe_fingerprint: "asdfas235afasa", purchase_state: "failed")
    assert_includes Purchase.stripe_failed, failed_with_fingerprint
  end

  test "scopes stripe_failed does not return successful purchases" do
    successful_with_fingerprint = create_purchase(stripe_fingerprint: "asdfas235afasa", purchase_state: "successful")
    assert_not_includes Purchase.stripe_failed, successful_with_fingerprint
  end

  test "scopes stripe_failed does not return failed purchases with blank stripe fingerprint" do
    failed_no_fingerprint = create_purchase(stripe_fingerprint: nil, purchase_state: "failed")
    assert_not_includes Purchase.stripe_failed, failed_no_fingerprint
  end

  # --- non_free ---
  test "scopes non_free returns purchases with fee > 0" do
    non_zero_fee = create_purchase
    assert_includes Purchase.non_free, non_zero_fee
  end

  test "scopes non_free does not return purchases with 0 fee" do
    zero_fee = create_free_purchase(link: create_product(price_range: "0+"))
    assert_not_includes Purchase.non_free, zero_fee
  end

  # --- paid ---
  test "scopes paid returns non-refunded non-free purchases" do
    non_refunded_purchase = create_purchase(price_cents: 300, stripe_refunded: nil)
    assert_includes Purchase.paid, non_refunded_purchase
  end

  test "scopes paid does not return refunded purchases" do
    refunded_purchase = create_purchase(price_cents: 300, stripe_refunded: true)
    assert_not_includes Purchase.paid, refunded_purchase
  end

  test "scopes paid does not return free purchases" do
    free_purchase = create_purchase(link: create_product(price_range: "0+"), price_cents: 0, stripe_transaction_id: nil, stripe_fingerprint: nil, charge_processor_id: nil, merchant_account: nil)
    assert_not_includes Purchase.paid, free_purchase
  end

  test "scopes paid has charge processor id set" do
    non_refunded_purchase = create_purchase(price_cents: 300, stripe_refunded: nil)
    free_purchase = create_purchase(link: create_product(price_range: "0+"), price_cents: 0, stripe_transaction_id: nil, stripe_fingerprint: nil, charge_processor_id: nil, merchant_account: nil)
    refunded_purchase = create_purchase(price_cents: 300, stripe_refunded: true)
    assert non_refunded_purchase.charge_processor_id.present?
    assert_nil free_purchase.charge_processor_id
    assert refunded_purchase.charge_processor_id.present?
  end

  # --- not_fully_refunded ---
  test "scopes not_fully_refunded returns non-refunded purchases" do
    non_refunded_purchase = create_purchase(stripe_refunded: nil)
    assert_includes Purchase.not_fully_refunded, non_refunded_purchase
  end

  test "scopes not_fully_refunded does not return refunded purchases" do
    refunded_purchase = create_purchase(stripe_refunded: true)
    assert_not_includes Purchase.not_fully_refunded, refunded_purchase
  end

  # --- not_chargedback ---
  test "scopes not_chargedback does not return chargebacked purchase" do
    chargebacked_purchase = create_purchase(chargeback_date: Date.yesterday)
    reversed_chargebacked_purchase = create_purchase(chargeback_date: Date.yesterday, chargeback_reversed: true)
    assert_not_includes Purchase.not_chargedback, chargebacked_purchase
    assert_not_includes Purchase.not_chargedback, reversed_chargebacked_purchase
  end

  test "scopes not_chargedback returns non-chargebacked purchase" do
    reversed_chargebacked_purchase = create_purchase(chargeback_date: Date.yesterday, chargeback_reversed: true)
    non_chargebacked_purchase = create_purchase
    assert_includes Purchase.not_chargedback, non_chargebacked_purchase
    assert_not_includes Purchase.not_chargedback, reversed_chargebacked_purchase
  end

  # --- not_chargedback_or_chargedback_reversed ---
  test "scopes not_chargedback_or_chargedback_reversed does not return chargebacked purchase" do
    chargebacked_purchase = create_purchase(chargeback_date: Date.yesterday)
    assert_not_includes Purchase.not_chargedback_or_chargedback_reversed, chargebacked_purchase
  end

  test "scopes not_chargedback_or_chargedback_reversed returns non-chargebacked purchase" do
    non_chargebacked_purchase = create_purchase
    assert_includes Purchase.not_chargedback_or_chargedback_reversed, non_chargebacked_purchase
  end

  test "scopes not_chargedback_or_chargedback_reversed returns chargebacked reversed purchase" do
    reversed_chargebacked_purchase = create_purchase(chargeback_date: Date.yesterday, chargeback_reversed: true)
    assert_includes Purchase.not_chargedback_or_chargedback_reversed, reversed_chargebacked_purchase
  end

  # --- additional contribution and max purchase quantity ---
  test "scopes additional contribution and max purchase quantity does not count the additional contribution towards the max quantity" do
    product = create_product(max_purchase_count: 1)
    create_purchase(link: product, is_additional_contribution: true)
    assert_equal 1, product.remaining_for_sale_count
  end

  # --- not_additional_contribution ---
  test "scopes not_additional_contribution returns puchases that are not additional contributions" do
    not_additional_contribution = create_purchase
    assert_includes Purchase.not_additional_contribution, not_additional_contribution
  end

  test "scopes not_additional_contribution does not return purchases that are additional contribution" do
    additional_contribution = create_purchase(is_additional_contribution: true)
    assert_not_includes Purchase.not_additional_contribution, additional_contribution
  end

  # --- not_recurring_charge ---
  test "scopes not_recurring_charge does not return purchases that are subscriptions and not original_subscription_purchase" do
    subscription = create_subscription
    # A recurring charge derives its price from the subscription's original purchase,
    # so create that first (mirrors the RSpec shared `before`).
    create_purchase(subscription:, is_original_subscription_purchase: true)
    recurring_purchase = create_purchase(subscription:, is_original_subscription_purchase: false)
    assert_not_includes Purchase.not_recurring_charge, recurring_purchase
  end

  test "scopes not_recurring_charge returns purchases that are original_subscription_purchase" do
    subscription = create_subscription
    original_subscription_purchase = create_purchase(subscription:, is_original_subscription_purchase: true)
    assert_includes Purchase.not_recurring_charge, original_subscription_purchase
  end

  test "scopes not_recurring_charge returns normal purchases" do
    normal_purchase = create_purchase
    assert_includes Purchase.not_recurring_charge, normal_purchase
  end

  # --- recurring_charge ---
  test "scopes recurring_charge does not return purchases that are original_subscription_purchase" do
    subscription = create_subscription
    original_subscription_purchase = create_purchase(subscription:, is_original_subscription_purchase: true)
    assert_not_includes Purchase.recurring_charge, original_subscription_purchase
  end

  test "scopes recurring_charge returns purchases that are original_subscription_purchase" do
    subscription = create_subscription
    # A recurring charge derives its price from the subscription's original purchase,
    # so create that first (mirrors the RSpec shared `before`).
    create_purchase(subscription:, is_original_subscription_purchase: true)
    recurring_purchase = create_purchase(subscription:, is_original_subscription_purchase: false)
    assert_includes Purchase.recurring_charge, recurring_purchase
  end

  test "scopes recurring_charge does not return normal purchases" do
    normal_purchase = create_purchase
    assert_not_includes Purchase.recurring_charge, normal_purchase
  end

  # --- .paypal_orders ---
  test "scopes .paypal_orders returns only paypal order purchases" do
    paypal_order_purchase = create_purchase(paypal_order_id: "SamplePaypalOrderID")
    non_paypal_order_purchase = create_purchase
    assert_includes Purchase.paypal_orders, paypal_order_purchase
    assert_not_includes Purchase.paypal_orders, non_paypal_order_purchase
  end

  # --- .unsuccessful_paypal_orders ---
  test "scopes .unsuccessful_paypal_orders returns only unsuccessful paypal order purchases created in specified time" do
    unsuccessful_paypal_order_purchase = create_purchase(paypal_order_id: "SamplePaypalOrderID1", purchase_state: "in_progress", created_at: 1.hour.ago)
    obsolete_unsuccessful_paypal_order_purchase = create_purchase(paypal_order_id: "SamplePaypalOrderID1", purchase_state: "in_progress", created_at: 4.hours.ago)
    recent_unsuccessful_paypal_order_purchase = create_purchase(paypal_order_id: "SamplePaypalOrderID2", purchase_state: "in_progress", created_at: 1.minute.ago)
    successful_paypal_order_purchase = create_purchase(paypal_order_id: "SamplePaypalOrderID3", purchase_state: "successful", created_at: 1.hour.ago)
    successful_non_paypal_order_purchase = create_purchase(purchase_state: "successful", created_at: 1.hour.ago)
    unsuccessful_non_paypal_order_purchase = create_purchase(purchase_state: "in_progress", created_at: 1.hour.ago)

    result = Purchase.unsuccessful_paypal_orders(2.5.hours.ago, 0.5.hours.ago)
    assert_includes result, unsuccessful_paypal_order_purchase
    assert_not_includes result, obsolete_unsuccessful_paypal_order_purchase
    assert_not_includes result, recent_unsuccessful_paypal_order_purchase
    assert_not_includes result, successful_paypal_order_purchase
    assert_not_includes result, successful_non_paypal_order_purchase
    assert_not_includes result, unsuccessful_non_paypal_order_purchase
  end

  # --- .with_credit_card_id ---
  # HTTP: creating a CreditCard tokenizes a card and creates a Stripe customer.
  test "scopes .with_credit_card_id returns the records with a credit_card_id value present" do
    purchase1 = purchase2 = purchase3 = nil
    VCR.use_cassette("Purchase/scopes/_with_credit_card_id/returns_the_records_with_a_credit_card_id_value_present") do
      purchase1 = create_purchase(credit_card_id: create_credit_card.id)
      purchase2 = create_purchase
      purchase3 = create_purchase(credit_card_id: create_credit_card.id)
    end

    result = Purchase.with_credit_card_id
    assert_includes result, purchase1
    assert_not_includes result, purchase2
    assert_includes result, purchase3
  end

  # --- .not_rental_expired ---
  test "scopes .not_rental_expired returns purchases where rental_expired field is nil or false" do
    purchase1 = create_purchase(rental_expired: true)
    purchase2 = create_purchase(rental_expired: false)
    purchase3 = create_purchase(rental_expired: nil)
    assert_includes Purchase.not_rental_expired, purchase2
    assert_includes Purchase.not_rental_expired, purchase3
    assert_not_includes Purchase.not_rental_expired, purchase1
  end

  # --- .for_library ---
  test "scopes .for_library excludes archived original subscription purchases" do
    purchase = create_purchase(is_archived_original_subscription_purchase: true)
    assert_not_includes Purchase.for_library, purchase
  end

  test "scopes .for_library includes updated original subscription purchases with not_charged state" do
    purchase = create_purchase(purchase_state: "not_charged")
    assert_includes Purchase.for_library, purchase
  end

  test "scopes .for_library excludes purchase with access revoked" do
    purchase = create_purchase(is_access_revoked: true)
    assert_not_includes Purchase.for_library, purchase
  end

  # --- .for_mobile_listing ---
  test "scopes .for_mobile_listing returns successful purchases" do
    digital = create_purchase(purchase_state: "successful")
    subscription = create_purchase(is_original_subscription_purchase: true, purchase_state: "successful")
    updated_subscription = create_purchase(is_original_subscription_purchase: true, purchase_state: "not_charged")
    archived = create_purchase(purchase_state: "successful", is_archived: true)
    gift = create_purchase(purchase_state: "gift_receiver_purchase_successful")

    assert_equal Set.new([digital, subscription, updated_subscription, gift, archived]), Set.new(Purchase.for_mobile_listing)
  end

  test "scopes .for_mobile_listing excludes failed, refunded or chargedback, gift sender, recurring charge, buyer deleted, and expired rental purchases" do
    create_purchase(purchase_state: "failed")
    create_purchase(purchase_state: "successful", is_additional_contribution: true)
    create_purchase(purchase_state: "successful", is_gift_sender_purchase: true)
    create_purchase(purchase_state: "successful", stripe_refunded: true)
    create_purchase(purchase_state: "successful", chargeback_date: 1.day.ago)
    create_purchase(purchase_state: "successful", rental_expired: true)
    create_purchase(purchase_state: "successful", is_deleted_by_buyer: true)
    original_purchase = create_membership_purchase
    create_membership_purchase(purchase_state: "successful", is_original_subscription_purchase: false, subscription: original_purchase.subscription)
    create_membership_purchase(purchase_state: "successful", is_original_subscription_purchase: true, is_archived_original_subscription_purchase: true)

    assert_empty Purchase.where.not(id: original_purchase.id).for_mobile_listing
  end

  # --- .for_sales_api ---
  test "scopes .for_sales_api includes successful purchases" do
    purchase = create_purchase(purchase_state: "successful")
    assert_equal [purchase], Purchase.for_sales_api.to_a
  end

  test "scopes .for_sales_api includes free trial not_charged purchases" do
    purchase = create_free_trial_membership_purchase
    assert_equal [purchase], Purchase.for_sales_api.to_a
  end

  test "scopes .for_sales_api does not include other purchases" do
    %w(
      failed
      gift_receiver_purchase_successful
      preorder_authorization_successful
      test_successful
    ).each do |purchase_state|
      create_purchase(purchase_state:)
    end
    original_purchase = create_membership_purchase(is_archived_original_subscription_purchase: true)
    create_membership_purchase(subscription: original_purchase.subscription, link: original_purchase.link, purchase_state: "not_charged")

    assert_equal [original_purchase], Purchase.for_sales_api.to_a
  end

  # --- .for_visible_posts ---
  test "scopes .for_visible_posts returns only eligible purchases for viewing posts" do
    buyer = create_user
    successful_purchase = create_purchase(purchaser: buyer, purchase_state: "successful")
    free_trial_purchase = create_free_trial_membership_purchase(user: buyer)
    gift_purchase = create_purchase(purchase_state: "gift_receiver_purchase_successful", purchaser: buyer)
    preorder_authorization_purchase = create_purchase(purchase_state: "preorder_authorization_successful", purchaser: buyer)
    membership_purchase = create_membership_purchase(purchaser: buyer)
    physical_purchase = create_physical_purchase(purchaser: buyer)
    create_purchase(purchaser: buyer, stripe_refunded: true)      # refunded
    create_purchase(purchaser: buyer, purchase_state: "failed")   # failed
    create_purchase(purchaser: buyer, purchase_state: "in_progress") # in progress
    create_purchase(purchaser: buyer, chargeback_date: 1.day.ago) # disputed
    create_purchase(purchase_state: "successful")                 # different purchaser

    assert_equal(
      Set.new([successful_purchase, free_trial_purchase, gift_purchase, preorder_authorization_purchase, membership_purchase, physical_purchase]),
      Set.new(Purchase.for_visible_posts(purchaser_id: buyer.id))
    )
  end

  # --- .exclude_not_charged_except_free_trial ---
  test "scopes .exclude_not_charged_except_free_trial excludes purchases that are not_charged but are not free trial purchases" do
    included_purchases = %w(
      successful
      failed
      gift_receiver_purchase_successful
      preorder_authorization_successful
      test_successful
    ).map do |purchase_state|
      create_purchase(purchase_state:)
    end
    included_purchases << create_free_trial_membership_purchase
    create_purchase(purchase_state: "not_charged")
    assert_equal Set.new(included_purchases), Set.new(Purchase.exclude_not_charged_except_free_trial)
  end

  # --- .no_or_active_subscription ---
  test "scopes .no_or_active_subscription returns non-subscription purchases and purchases with an active subscription" do
    normal_purchase = create_purchase
    subscription = create_subscription
    subscription_purchase = create_purchase(subscription:, is_original_subscription_purchase: true)

    assert_equal [normal_purchase, subscription_purchase], Purchase.no_or_active_subscription.to_a
  end

  test "scopes .no_or_active_subscription does not include purchases with inactive subscription" do
    normal_purchase = create_purchase
    subscription = create_subscription(deactivated_at: 1.day.ago)
    create_purchase(subscription:, is_original_subscription_purchase: true)

    assert_equal [normal_purchase], Purchase.no_or_active_subscription.to_a
  end

  # --- .inactive_subscription ---
  test "scopes .inactive_subscription returns subscription purchases which have been deactivated" do
    create_purchase
    active_subscription = create_subscription
    create_purchase(subscription: active_subscription, is_original_subscription_purchase: true)
    deactivated_subscription = create_subscription(deactivated_at: 1.day.ago)
    deactivated_subscription_purchase = create_purchase(subscription: deactivated_subscription, is_original_subscription_purchase: true)

    assert_equal [deactivated_subscription_purchase], Purchase.inactive_subscription.to_a
  end

  # --- .can_access_content ---
  test "scopes .can_access_content includes non-subscription purchases" do
    purchase = create_purchase
    assert_equal [purchase], Purchase.can_access_content.to_a
  end

  test "scopes .can_access_content includes active subscription purchases" do
    purchase = create_membership_purchase
    assert_equal [purchase], Purchase.can_access_content.to_a
  end

  test "scopes .can_access_content includes inactive subscription purchases where subscribers are allowed to access product content after the subscription has lapsed" do
    purchase = create_membership_purchase
    purchase.subscription.update!(deactivated_at: 1.minute.ago)
    assert_equal [purchase], Purchase.can_access_content.to_a
  end

  test "scopes .can_access_content excludes inactive subscription purchases if subscribers should lose access when subscription lapses" do
    purchase = create_membership_purchase
    subscription = purchase.subscription
    subscription.update!(deactivated_at: 1.minute.ago)
    subscription.link.update!(block_access_after_membership_cancellation: true)
    assert_empty Purchase.can_access_content
  end

  # ============================ lifecycle hooks ============================

  test "lifecycle hooks check perceived_price_cents_matches_price_cents adds a buyer-facing error without an attribute-name prefix if the perceived price is different from the product price" do
    product = create_product(price_cents: 10_00)
    purchase = build_purchase(link: product, perceived_price_cents: 5_00)
    purchase.save

    # Checkout shows errors.full_messages to buyers verbatim, so the message must not
    # carry a humanized attribute prefix like "Price cents".
    assert_includes purchase.errors.full_messages, "The price just changed! Refresh the page for the updated price."
    assert_equal PurchaseErrorCode::PERCEIVED_PRICE_CENTS_NOT_MATCHING, purchase.error_code
  end

  test "lifecycle hooks check perceived_price_cents_matches_price_cents returns true if the purchase is_upgrade_purchase" do
    product = create_product(price_cents: 10_00)
    purchase = build_purchase(link: product, perceived_price_cents: 5_00)
    purchase.is_upgrade_purchase = true
    purchase.save

    assert_empty purchase.errors.full_messages
  end

  # ============================ not_for_sale ============================

  test "not_for_sale doesn't allow purchases of unpublished products" do
    link = create_product(purchase_disabled_at: Time.current)
    purchase = create_purchase(link:, seller: link.user)
    assert purchase.errors[:base].present?
    assert_equal PurchaseErrorCode::NOT_FOR_SALE, purchase.error_code
  end

  test "not_for_sale allows purchases when is_commission_completion_purchase is true even if product is unpublished" do
    link = create_product(purchase_disabled_at: Time.current)
    purchase = create_purchase(link:, seller: link.user, is_commission_completion_purchase: true)
    assert_not purchase.errors[:base].present?
    assert_nil purchase.error_code
  end

  # ============================ temporarily blocked product ============================

  test "temporarily blocked product when the price is zero allows the purchase of temporarily blocked products" do
    Feature.activate(:block_purchases_on_product)
    product = create_product
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:product], object_value: product.id, expires_in: 6.hours)
    product.price_cents = 0

    purchase = create_purchase(price_cents: 0, link: product)

    assert_equal "successful", purchase.purchase_state
    assert purchase.error_code.blank?
  end

  test "temporarily blocked product when the price is not zero doesn't allow purchases of temporarily blocked products" do
    Feature.activate(:block_purchases_on_product)
    product = create_product
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:product], object_value: product.id, expires_in: 6.hours)

    purchase = create_purchase(link: product)

    assert purchase.errors[:base].present?
    assert_equal PurchaseErrorCode::TEMPORARILY_BLOCKED_PRODUCT, purchase.error_code
    assert_includes purchase.errors.full_messages, "Your card was not charged."
  end

  # ============================ sold_out ============================

  test "sold_out doesn't allow purchase once sold out" do
    link = create_product(max_purchase_count: 1)
    create_purchase(link:, seller: link.user)
    p2 = create_purchase(link:, purchase_state: "in_progress")
    assert p2.errors[:base].present?
    assert_equal PurchaseErrorCode::PRODUCT_SOLD_OUT, p2.error_code
  end

  test "sold_out doesn't count failed purchases towards the sold-out count" do
    link = create_product(max_purchase_count: 1)
    create_purchase(link:, purchase_state: "failed")
    p2 = create_purchase(link:)
    assert p2.valid?
    p3 = create_purchase(link:, purchase_state: "in_progress")
    assert p3.errors[:base].present?
    assert_equal PurchaseErrorCode::PRODUCT_SOLD_OUT, p3.error_code
  end

  test "sold_out allows saving a purchase when sold out" do
    link = create_product(max_purchase_count: 1)
    purchase = create_purchase(link:, seller: link.user)
    purchase.email = "testingtesting123@example.org"
    assert purchase.save
  end

  test "sold_out doesn't count additional contributions toward max_purchase_count" do
    link = create_product(max_purchase_count: 1)
    create_purchase(link:, seller: link.user)
    p2 = create_purchase(link:, is_additional_contribution: true)
    assert p2.valid?
    p3 = create_purchase(link:)
    assert p3.errors[:base].present?
    assert_equal PurchaseErrorCode::PRODUCT_SOLD_OUT, p3.error_code
  end

  test "sold_out doesn't allow purchase once sold out (product variant naming)" do
    product = create_product(max_purchase_count: 1)
    create_purchase(link: product)
    purchase_2 = create_purchase(link: product, purchase_state: "in_progress")
    assert purchase_2.errors[:base].present?
    assert_equal PurchaseErrorCode::PRODUCT_SOLD_OUT, purchase_2.error_code
  end

  test "sold_out when the product's sales_count_for_inventory returns nil treats nil as 0 instead of raising TypeError" do
    product = create_product(max_purchase_count: 5)
    purchase = build_purchase(link: product, quantity: 1)
    purchase.stubs(:link).returns(product)
    product.stubs(:sales_count_for_inventory).returns(nil)
    assert_nothing_raised { purchase.send(:sold_out) }
    assert_empty purchase.errors[:base]
  end

  test "sold_out subscriptions does not count recurring charges towards the max_purchase_count" do
    product = create_membership_product(subscription_duration: :monthly, max_purchase_count: 1)
    create_purchase(link: product, subscription: create_subscription(link: product), is_original_subscription_purchase: true)
    recurring_charge = build_purchase(is_original_subscription_purchase: false, subscription: create_subscription(link: product), link: product)
    assert recurring_charge.valid?
  end

  test "sold_out subscriptions does count original_subscription_purchase towards max_purchase_count" do
    product = create_membership_product(subscription_duration: :monthly, max_purchase_count: 1)
    create_purchase(link: product, subscription: create_subscription(link: product), is_original_subscription_purchase: true)
    purchase = create_purchase(link: product, subscription: create_subscription, is_original_subscription_purchase: true)
    assert purchase.errors[:base].present?
    assert_equal PurchaseErrorCode::PRODUCT_SOLD_OUT, purchase.error_code
  end

  # ============================ variants_available ============================

  test "variants_available succeeds when all variants are available for the given quantities" do
    product = create_product
    variant_category = create_variant_category(link: product)
    variant1 = create_variant(variant_category:, max_purchase_count: 2)
    variant2 = create_variant(variant_category:)
    purchase = create_purchase(link: product, variant_attributes: [variant1, variant2])
    assert purchase.errors.blank?
  end

  test "variants_available fails if at least one variant is not available for the given quantity" do
    product = create_product
    variant_category = create_variant_category(link: product)
    variant1 = create_variant(variant_category:, max_purchase_count: 2)
    variant2 = create_variant(variant_category:)
    purchase = create_purchase(link: product, variant_attributes: [variant1, variant2], quantity: 3)
    assert_includes purchase.errors.full_messages, "You have chosen a quantity that exceeds what is available."
  end

  test "variants_available fails if at least one variant is unavailable because it is deleted" do
    product = create_product
    variant_category = create_variant_category(link: product)
    variant1 = create_variant(variant_category:, max_purchase_count: 2)
    variant2 = create_variant(variant_category:)
    variant2.mark_deleted!
    purchase = create_purchase(link: product, variant_attributes: [variant1, variant2])
    assert_includes purchase.errors.full_messages, "Sold out, please go back and pick another option."
  end

  test "variants_available fails if at least one variant is unavailable because it is sold out" do
    product = create_product
    variant_category = create_variant_category(link: product)
    variant1 = create_variant(variant_category:, max_purchase_count: 2)
    variant2 = create_variant(variant_category:)
    create_purchase(link: product, variant_attributes: [variant1], quantity: 2)
    purchase = create_purchase(link: product, variant_attributes: [variant1, variant2])
    assert_includes purchase.errors.full_messages, "Sold out, please go back and pick another option."
  end

  test "variants_available when original_variant_attributes is set succeeds even when an original variant is sold out or marked deleted" do
    product = create_product
    variant_category = create_variant_category(link: product)
    variant1 = create_variant(variant_category:, max_purchase_count: 2)
    variant2 = create_variant(variant_category:)
    purchase = create_purchase(link: product, variant_attributes: [variant1, variant2], quantity: 2)
    variant1.update!(max_purchase_count: 2)
    variant2.mark_deleted!

    purchase.original_variant_attributes = [variant1, variant2]
    purchase.save
    assert purchase.errors.blank?
  end

  test "variants_available when original_variant_attributes is set fails when at least one new variant is sold out" do
    product = create_product
    variant_category = create_variant_category(link: product)
    variant1 = create_variant(variant_category:, max_purchase_count: 2)
    variant2 = create_variant(variant_category:)
    variant3 = create_variant(variant_category:, max_purchase_count: 1)
    create_purchase(link: product, variant_attributes: [variant3])

    purchase = build_purchase(link: product, variant_attributes: [variant1, variant2, variant3])
    purchase.original_variant_attributes = [variant1, variant2]
    purchase.save
    assert_includes purchase.errors.full_messages, "Sold out, please go back and pick another option."
  end

  # ============================ #as_json ============================

  test "#as_json has the right keys" do
    @purchase = create_as_json_purchase
    %i[price gumroad_fee seller_id link_name timestamp daystamp chargedback paypal_refund_expired].each do |key|
      assert @purchase.as_json.key?(key), "expected as_json to have key #{key}"
    end

    assert_equal "sahil@gumroad.com", @purchase.as_json[:email]
    assert_equal "Sahil Lavingia", @purchase.as_json[:full_name]
  end

  test "#as_json includes web CSV parity fields for v2 only" do
    purchase = create_purchase
    utm_link = create_utm_link(seller: purchase.seller, utm_source: "newsletter", utm_medium: "email", utm_campaign: "launch", utm_term: "founders", utm_content: "hero")
    create_utm_link_driven_sale(utm_link:, purchase:)
    create_tip(purchase:, value_usd_cents: 350)
    category = create_variant_category(link: purchase.link, title: "Format")
    variant = create_variant(variant_category: category, name: "Premium", price_difference_cents: 250)
    purchase.variant_attributes << variant
    create_product_review(purchase:, rating: 5, message: "Worth it")
    cancellation_date = Time.zone.parse("2026-01-02 03:04:05")
    subscription = create_subscription(user: purchase.seller, link: purchase.link)
    subscription.update!(user_requested_cancellation_at: cancellation_date, cancelled_at: Date.new(2026, 1, 10))
    preorder = create_preorder(seller: purchase.seller, preorder_link: create_preorder_link(link: purchase.link), created_at: Time.zone.parse("2025-12-01 08:00:00"))
    cart = create_cart(order: create_order(purchases: [purchase]))
    workflow = create_abandoned_cart_workflow(seller: purchase.seller)
    create_sent_abandoned_cart_email(cart:, installment: workflow.installments.sole)
    merchant_account = create_merchant_account_stripe_connect(user: purchase.seller)

    purchase.update!(
      was_purchase_taxable: true,
      was_tax_excluded_from_price: false,
      tax_cents: 123,
      shipping_cents: 456,
      is_access_revoked: true,
      subscription:,
      preorder:,
      is_original_subscription_purchase: true,
      is_preorder_authorization: false,
      merchant_account:,
      processor_fee_cents: 78,
      processor_fee_cents_currency: "usd",
      stripe_transaction_id: "ch_123"
    )

    v2_json = purchase.reload.as_json(version: 2)
    assert_json_includes({
                           utm_source: "newsletter",
                           utm_medium: "email",
                           utm_campaign: "launch",
                           utm_term: "founders",
                           utm_content: "hero",
                           tip_cents: 350,
                           tax_cents: 123,
                           shipping_cents: 456,
                           tax_label: "Sales tax",
                           tax_included_in_price: true,
                           payment_processor: "stripe_connect",
                           processor_transaction_id: "ch_123",
                           processor_fee_cents: 78,
                           processor_fee_currency: "usd",
                           access_revoked: true,
                           preorder_authorization_time: preorder.reload.created_at,
                           variants_price_cents: 250,
                           review: "Worth it",
                           cancellation_date: subscription.reload.user_requested_cancellation_at,
                           subscription_end_date: Date.new(2026, 1, 10),
                           sent_abandoned_cart_email: true
                         }, v2_json)

    refute_json_keys(%i[
                       utm_source utm_medium utm_campaign utm_term utm_content tip_cents tax_cents shipping_cents
                       tax_label tax_included_in_price payment_processor processor_transaction_id processor_fee_cents
                       processor_fee_currency access_revoked preorder_authorization_time variants_price_cents review
                       cancellation_date subscription_end_date sent_abandoned_cart_email
                     ], purchase.as_json)
  end

  test "#as_json omits optional web CSV parity fields when no corresponding data exists" do
    @purchase = create_as_json_purchase
    json = @purchase.as_json(version: 2)

    assert_json_includes({
                           tax_cents: 0,
                           shipping_cents: 0,
                           access_revoked: false,
                           variants_price_cents: 0,
                           sent_abandoned_cart_email: false
                         }, json)
    refute_json_keys(%i[
                       utm_source tip_cents tax_label tax_included_in_price payment_processor processor_transaction_id
                       processor_fee_cents processor_fee_currency preorder_authorization_time review cancellation_date
                       subscription_end_date
                     ], json)
  end

  test "#as_json includes the giftee review for gift sender purchases in v2 web CSV parity fields" do
    product = create_product
    gift_sender_purchase = create_purchase(link: product, is_gift_sender_purchase: true)
    giftee_purchase = create_purchase(link: product, is_gift_receiver_purchase: true, purchase_state: "gift_receiver_purchase_successful")
    create_gift(link: product, gifter_purchase: gift_sender_purchase, giftee_purchase:)
    create_product_review(purchase: giftee_purchase, rating: 5, message: "The giftee loved it")

    assert_json_includes({ review: "The giftee loved it" }, gift_sender_purchase.reload.as_json(version: 2))
  end

  test "#as_json exposes processor fields for PayPal marketplace sales" do
    @purchase = create_as_json_purchase
    @purchase.update!(
      paypal_order_id: "paypal_order_123",
      stripe_transaction_id: "paypal_tx_123",
      processor_fee_cents: 91,
      processor_fee_cents_currency: "usd"
    )

    assert_json_includes({
                           payment_processor: "paypal",
                           processor_transaction_id: "paypal_tx_123",
                           processor_fee_cents: 91,
                           processor_fee_currency: "usd"
                         }, @purchase.reload.as_json(version: 2))
  end

  test "#as_json returns paypal_refund_expired as true for unrefundable PayPal purchases and false for others" do
    @purchase = create_as_json_purchase
    unrefundable_paypal_purchase = create_purchase(created_at: 7.months.ago, card_type: CardType::PAYPAL)
    assert_equal false, @purchase.as_json[:paypal_refund_expired]
    assert_equal true, unrefundable_paypal_purchase.as_json[:paypal_refund_expired]
  end

  test "#as_json has the right seller_id" do
    @purchase = create_as_json_purchase
    seller = @purchase.link.user
    assert_equal ObfuscateIds.encrypt(seller.id), @purchase.as_json[:seller_id]
  end

  test "#as_json has the right gumroad_fee" do
    @purchase = create_as_json_purchase
    assert_equal 93, @purchase.as_json[:gumroad_fee] # 10c (10%) + 50c + 3c (2.9% cc fee) + 30c (fixed cc fee)
    @purchase.update!(price_cents: 500)
    @purchase.send(:calculate_fees)
    assert_equal 145, @purchase.as_json[:gumroad_fee] # 50c (10%) + 50c + 15c (2.9% cc fee) + 30c (fixed cc fee)
  end

  test "#as_json uses the cached resolved discount amount for offer code display" do
    product = create_product(price_cents: 1000)
    offer_code = create_tiered_offer_code(user: product.user, products: [product], amount_percentage: 0)
    purchase = create_purchase(link: product, seller: product.user, offer_code:, price_cents: 500)
    purchase.create_purchase_offer_code_discount(offer_code:, offer_code_amount: 50, offer_code_is_percent: true, pre_discount_minimum_price_cents: 1000)

    assert_json_includes({
                           code: offer_code.code,
                           displayed_amount_off: "50%"
                         }, purchase.as_json[:offer_code])
  end

  test "#as_json has the purchaser_id if one exists" do
    @purchase = create_as_json_purchase
    assert_equal false, @purchase.as_json.key?(:purchaser_id)

    purchaser = create_user
    @purchase.update!(purchaser_id: purchaser.id)

    assert_equal purchaser.external_id, @purchase.as_json[:purchaser_id]
  end

  test "#as_json has the right daystamp" do
    @purchase = create_as_json_purchase
    day = 1.day.ago
    @purchase.seller.update_attribute(:timezone, "Pacific Time (US & Canada)")
    @purchase.update_attribute(:created_at, day)
    assert_equal day.in_time_zone("Pacific Time (US & Canada)").to_fs(:long_formatted_datetime), @purchase.as_json[:daystamp]
  end

  test "#as_json has the right iso2 code for the country" do
    @purchase = create_as_json_purchase
    @purchase.update_attribute(:country, "United States")
    assert_equal "US", @purchase.as_json[:country_iso2]
  end

  test "#as_json performs a safe country code lookup for a GeoIp2 country that isn't found in IsoCountryCodes" do
    @purchase = create_as_json_purchase
    @purchase.update!(country: "South Korea")
    assert_equal "South Korea", @purchase.as_json[:country]
    assert_equal "KR", @purchase.as_json[:country_iso2]
  end

  test "#as_json returns country and state as is if they are set" do
    @purchase = create_as_json_purchase
    @purchase.update!(country: "United States", state: "CA")
    assert_equal "United States", @purchase.as_json[:country]
    assert_equal "CA", @purchase.as_json[:state]
  end

  test "#as_json returns country and state based on ip_address if they don't exist" do
    @purchase = create_as_json_purchase
    @purchase.update!(ip_address: "199.241.200.176")
    assert_nil @purchase.country
    assert_nil @purchase.state
    assert_equal "United States", @purchase.as_json[:country]
    assert_equal "CA", @purchase.as_json[:state]
  end

  test "#as_json does not have sku id if not sku exists but product is sku enabled" do
    @purchase = create_as_json_purchase
    @purchase.link.update_attribute(:skus_enabled, true)
    assert_nil @purchase.as_json[:sku_id]
  end

  test "#as_json contains receipt_url only when include_receipt_url is set" do
    @purchase = create_as_json_purchase
    receipt_url = @purchase.receipt_url
    assert_nil @purchase.as_json[:receipt_url]
    assert_equal receipt_url, @purchase.as_json(include_receipt_url: true)[:receipt_url]
  end

  test "#as_json contains can_ping only when include_ping is set" do
    @purchase = create_as_json_purchase
    assert_equal false, @purchase.as_json.key?(:can_ping)
  end

  test "#as_json returns the correct value for can_ping when the user has notification endpoint set" do
    @purchase = create_as_json_purchase
    seller = @purchase.link.user
    seller.update!(notification_endpoint: "http://test/")

    with_can_ping_json = @purchase.as_json(include_ping: true)
    assert_equal true, with_can_ping_json[:can_ping]
  end

  test "#as_json returns the correct value for can_ping when the user has an oauth app" do
    @purchase = create_as_json_purchase
    seller = @purchase.link.user
    seller.update!(notification_endpoint: nil)
    sub = create_resource_subscription(user: seller, resource_name: ResourceSubscription::SALE_RESOURCE_NAME)
    Doorkeeper::AccessToken.create!(application_id: sub.oauth_application.id, resource_owner_id: seller.id, scopes: "view_sales")

    with_can_ping_json_oauth = @purchase.as_json(include_ping: true)
    assert_equal true, with_can_ping_json_oauth.key?(:can_ping)
    assert_equal true, with_can_ping_json_oauth[:can_ping]
  end

  test "#as_json returns the provided override for can_ping if provided" do
    @purchase = create_as_json_purchase
    seller = @purchase.link.user
    seller.update!(notification_endpoint: "http://test/")
    with_can_ping_cached_json = @purchase.as_json(include_ping: { value: false })

    assert_equal true, with_can_ping_cached_json.key?(:can_ping)
    assert_equal false, with_can_ping_cached_json[:can_ping]
  end

  test "#as_json returns the correct value for recurring_charge" do
    @purchase = create_as_json_purchase
    # A regular purchase
    assert_not @purchase.as_json.key?(:recurring_charge)

    # The first purchase of a subscription product
    link = create_membership_product(user: @purchase.link.user, subscription_duration: :monthly)
    subscription = create_subscription(user: @purchase.link.user, link:)
    purchase = create_purchase(link:, price_cents: link.price_cents, is_original_subscription_purchase: true, subscription:)
    assert_equal false, purchase.as_json[:recurring_charge]

    # The second (automatic) purchase of a subscription product
    purchase = create_purchase(link:, price_cents: link.price_cents, is_original_subscription_purchase: false, subscription:)
    assert_equal true, purchase.as_json[:recurring_charge]
  end

  test "#as_json returns information about the product" do
    @purchase = create_as_json_purchase
    assert @purchase.as_json.key?(:product_permalink)
    assert @purchase.as_json.key?(:product_name)
    assert @purchase.as_json.key?(:product_has_variants)
  end

  test "#as_json doesn't set the card expiry month and year fields" do
    purchase = create_purchase(card_expiry_month: 11, card_expiry_year: 2022)

    assert_nil purchase.as_json[:card][:expiry_month]
    assert_nil purchase.as_json[:card][:expiry_year]
  end

  test "#as_json returns the dispute information" do
    @purchase = create_as_json_purchase
    # Assert that the response has dispute_won and disputed = false
    @purchase.update!(chargeback_date: nil)
    assert_json_includes({ disputed: false, dispute_won: false }, @purchase.as_json)

    # Mark purchase as disputed
    @purchase.update!(chargeback_date: Time.current)
    assert_json_includes({ disputed: true, dispute_won: false }, @purchase.reload.as_json)

    # Mark purchase as dispute reversed
    @purchase.update!(chargeback_reversed: true)
    assert_json_includes({ disputed: true, dispute_won: true }, @purchase.reload.as_json)
  end

  test "#as_json includes relevant flags" do
    @purchase = create_as_json_purchase
    @purchase.update!(preorder: create_preorder)

    assert_equal false, @purchase.as_json[:is_preorder_authorization]
    assert_equal false, @purchase.as_json[:is_additional_contribution]
    assert_equal false, @purchase.as_json[:discover_fee_charged]
    assert_equal false, @purchase.as_json[:is_gift_sender_purchase]
    assert_equal false, @purchase.as_json[:is_gift_receiver_purchase]
    assert_equal false, @purchase.as_json[:is_upgrade_purchase]
  end

  test "#as_json falls back to the purchaser's name if full_name is blank" do
    @purchase = create_as_json_purchase
    @purchase.update! full_name: "", purchaser: create_user(name: "Mr Gumroadson")

    assert_equal "Mr Gumroadson", @purchase.as_json[:full_name]
  end

  test "#as_json when the product is of type subscription but not a tiered membership returns the correct value for subscription_duration when the default subscription period is opted for" do
    user = create_user
    product = create_subscription_product(user:, price_cents: 1000, subscription_duration: :monthly)
    monthly_subscription = create_subscription(user:, link: product)

    # The first purchase of a subscription product
    purchase = create_purchase(link: product, is_original_subscription_purchase: true, subscription: monthly_subscription)
    assert_equal "monthly", purchase.as_json[:subscription_duration]

    # The second (automatic) purchase of a subscription product
    purchase = create_purchase(link: product, is_original_subscription_purchase: false, subscription: monthly_subscription)
    assert_equal "monthly", purchase.as_json[:subscription_duration]
  end

  test "#as_json when the product is of type subscription but not a tiered membership returns the correct value for subscription_duration when a non-default subscription period is opted for" do
    user = create_user
    product = create_subscription_product(user:, price_cents: 1000, subscription_duration: :monthly)
    yearly_price = create_price(link: product, price_cents: 10_000, recurrence: BasePrice::Recurrence::YEARLY)
    yearly_subscription = create_subscription(user:, link: product)
    payment_option = yearly_subscription.payment_options.first
    payment_option.price = yearly_price
    payment_option.save!
    yearly_subscription.reload

    # The first purchase of a subscription product
    purchase = create_purchase(link: product, is_original_subscription_purchase: true, subscription: yearly_subscription)
    assert_equal "yearly", purchase.as_json[:subscription_duration]

    # The second (automatic) purchase of a subscription product
    purchase = create_purchase(link: product, is_original_subscription_purchase: false, subscription: yearly_subscription)
    assert_equal "yearly", purchase.as_json[:subscription_duration]
  end

  test "#as_json when the product is of type subscription and is a tiered membership returns the correct value for subscription_duration when the default subscription period is opted for" do
    product, monthly_subscription, = setup_tiered_membership_subscriptions

    # The first purchase of a subscription product
    purchase = create_purchase(link: product, is_original_subscription_purchase: true, subscription: monthly_subscription)
    assert_equal "monthly", purchase.as_json[:subscription_duration]

    # The second (automatic) purchase of a subscription product
    purchase = create_purchase(link: product, is_original_subscription_purchase: false, subscription: monthly_subscription)
    assert_equal "monthly", purchase.as_json[:subscription_duration]
  end

  test "#as_json when the product is of type subscription and is a tiered membership returns the correct value for subscription_duration when a non-default subscription period is opted for" do
    product, _monthly_subscription, yearly_subscription = setup_tiered_membership_subscriptions

    # The first purchase of a subscription product
    purchase = create_purchase(link: product, is_original_subscription_purchase: true, subscription: yearly_subscription)
    assert_equal "yearly", purchase.as_json[:subscription_duration]

    # The second (automatic) purchase of a subscription product
    purchase = create_purchase(link: product, is_original_subscription_purchase: false, subscription: yearly_subscription)
    assert_equal "yearly", purchase.as_json[:subscription_duration]
  end

  test "#as_json when the product is of type subscription and is a tiered membership and has a free trial returns the formatted free trial end date" do
    product, monthly_subscription, = setup_tiered_membership_subscriptions
    free_trial_ends_at = 1.day.ago
    monthly_subscription.update!(free_trial_ends_at:)
    purchase = create_purchase(link: product, is_original_subscription_purchase: true, subscription: monthly_subscription)

    assert_equal free_trial_ends_at.to_fs(:formatted_date_abbrev_month), purchase.as_json[:free_trial_ends_on]
  end

  test "#as_json when the product is of type subscription and is a tiered membership and has a free trial includes whether the free trial has ended" do
    product, monthly_subscription, = setup_tiered_membership_subscriptions
    free_trial_ends_at = 1.day.ago
    monthly_subscription.update!(free_trial_ends_at:)
    purchase = create_purchase(link: product, is_original_subscription_purchase: true, subscription: monthly_subscription)

    assert_equal true, purchase.as_json[:free_trial_ended]
  end

  test "#as_json does not contain subscription_duration in the return value for a product which is not of type subscription" do
    @purchase = create_as_json_purchase
    assert_not @purchase.as_json.key?(:subscription_duration)
  end

  test "#as_json with include_variant_details: true includes variant details regardless of skus_enabled" do
    @purchase = create_as_json_purchase
    product = @purchase.link
    category = create_variant_category(link: product, title: "Color")
    blue_variant = create_variant(variant_category: category, name: "Blue")
    @purchase.variant_attributes << blue_variant
    @purchase.save!
    @purchase.link.update!(skus_enabled: true)

    variants_json = @purchase.reload.as_json(include_variant_details: true)[:variants]

    assert_equal(
      {
        category.external_id => {
          title: category.title,
          selected_variant: {
            id: blue_variant.external_id,
            name: blue_variant.name
          }
        }
      },
      variants_json
    )
  end

  test "#as_json with include_variant_details: true includes SKU details regardless of skus_enabled" do
    @purchase = create_as_json_purchase
    product = @purchase.link
    category_1 = create_variant_category(link: product, title: "Color")
    category_2 = create_variant_category(link: product, title: "Size")
    sku_title = "#{category_1.title} - #{category_2.title}"
    sku = create_sku(link: product, name: "Blue - large")
    @purchase.variant_attributes << sku
    @purchase.save!
    @purchase.reload

    variants_json = @purchase.as_json(include_variant_details: true)[:variants]

    assert_equal(
      {
        sku_title => {
          is_sku: true,
          title: sku_title,
          selected_variant: {
            id: sku.external_id,
            name: sku.name
          }
        }
      },
      variants_json
    )
  end

  test "#as_json with include_variant_details: true includes empty hashes if no variants" do
    @purchase = create_as_json_purchase
    variants_json = @purchase.as_json(include_variant_details: true)[:variants]

    assert_equal({}, variants_json)
  end

  test "#as_json with creator_app_api: true includes the product's thumbnail url, if present" do
    @purchase = create_as_json_purchase
    json = @purchase.as_json(creator_app_api: true)
    assert_equal true, json.key?(:product_thumbnail_url)
    assert_nil json[:product_thumbnail_url]

    thumbnail = create_thumbnail(product: @purchase.link)
    json = @purchase.reload.as_json(creator_app_api: true)
    assert_equal thumbnail.url, json[:product_thumbnail_url]
  end

  test "#as_json with creator_app_api: true includes price & formatted_total_price" do
    purchase = create_purchase(price_cents: 400, displayed_price_cents: 300)
    json = purchase.as_json(creator_app_api: true)
    assert_equal "$3", json[:price]
    assert_equal "$4", json[:formatted_total_price]
  end

  test "#as_json with creator_app_api: true includes the refund state" do
    purchase = create_purchase # stripe_refunded => nil
    json = purchase.as_json(creator_app_api: true)
    assert_equal false, json[:refunded]

    purchase = create_purchase(stripe_refunded: false)
    json = purchase.as_json(creator_app_api: true)
    assert_equal false, json[:refunded]

    purchase = create_purchase(stripe_refunded: true)
    json = purchase.as_json(creator_app_api: true)
    assert_equal true, json[:refunded]

    purchase = create_purchase # stripe_partially_refunded => false
    json = purchase.as_json(creator_app_api: true)
    assert_equal false, json[:partially_refunded]

    purchase = create_purchase(stripe_partially_refunded: true)
    json = purchase.as_json(creator_app_api: true)
    assert_equal true, json[:partially_refunded]
  end

  test "#as_json with creator_app_api: true includes the chargeback state" do
    purchase = create_purchase
    json = purchase.as_json(creator_app_api: true)
    assert_equal false, json[:chargedback]

    purchase.update!(chargeback_date: Time.current)
    json = purchase.as_json(creator_app_api: true)
    assert_equal true, json[:chargedback]

    purchase.update!(chargeback_reversed: true)
    json = purchase.as_json(creator_app_api: true)
    assert_equal false, json[:chargedback]
  end

  test "#as_json with query returns paypal_email when it matches query" do
    @purchase = create_as_json_purchase
    paypal_email = "jane@paypal.com"
    @purchase.update!(card_visual: paypal_email)

    assert_equal paypal_email, @purchase.as_json(query: paypal_email)[:paypal_email]
  end

  test "#as_json with query does not return paypal_email when it matches query but not an email" do
    @purchase = create_as_json_purchase
    query = "test_card"
    @purchase.update!(card_visual: query)

    assert_nil @purchase.as_json(query:)[:paypal_email]
  end

  test "#as_json with query does not return paypal_email when it does not match a query" do
    @purchase = create_as_json_purchase
    paypal_email = "jane@paypal.com"
    @purchase.update!(card_visual: paypal_email)

    assert_nil @purchase.as_json(query: "xxx")[:paypal_email]
  end

  test "#as_json with pundit_user contains can_revoke_access and can_undo_revoke_access" do
    @purchase = create_as_json_purchase
    user = create_user
    seller = @purchase.seller
    create_team_membership(user:, seller:, role: TeamMembership::ROLE_ADMIN)
    pundit_user = SellerContext.new(user:, seller:)

    hash_data = @purchase.as_json(pundit_user:)
    assert_equal true, hash_data[:can_revoke_access]
    assert_equal false, hash_data[:can_undo_revoke_access]
  end

  test "#as_json upsells when there isn't an upsell purchase doesn't include upsell information" do
    @purchase = create_as_json_purchase
    assert_nil @purchase.as_json[:upsell]
  end

  test "#as_json upsells when there is an upsell purchase includes upsell information" do
    upsell_purchase = create_upsell_purchase
    assert_equal upsell_purchase.as_json, upsell_purchase.purchase.as_json[:upsell]
  end

  test "#as_json when the purchase was recommended by more like this returns true for is_more_like_this_recommended" do
    @purchase = create_as_json_purchase
    @purchase.update(recommended_by: RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION)
    assert_equal true, @purchase.as_json[:is_more_like_this_recommended]
  end

  test "#as_json with custom fields returns the correct format for version 1" do
    @purchase = create_as_json_purchase
    @purchase.purchase_custom_fields << build_purchase_custom_field(name: "custom", value: "value")
    @purchase.purchase_custom_fields << build_purchase_custom_field(name: "boolean", value: "true", type: CustomField::TYPE_CHECKBOX)
    assert_equal ["custom: value", "boolean: true"], @purchase.as_json[:custom_fields]
  end

  test "#as_json with custom fields returns the correct format for version 2" do
    @purchase = create_as_json_purchase
    @purchase.purchase_custom_fields << build_purchase_custom_field(name: "custom", value: "value")
    @purchase.purchase_custom_fields << build_purchase_custom_field(name: "boolean", value: "true", type: CustomField::TYPE_CHECKBOX)
    assert_equal({ "custom" => "value", "boolean" => true }, @purchase.as_json(version: 2)[:custom_fields])
  end

  # ============================ top-level examples ============================

  test "allows > $1000 if seller is verified" do
    assert build_purchase(link: create_product(user: create_user(verified: true)), price_cents: 100_100).valid?
  end

  test "has an address and name when the link requires it" do
    purchase = build_purchase(street_address: nil, link: create_product(require_shipping: true))
    assert_not purchase.valid?
    %i[full_name street_address country state city zip_code].each do |w|
      assert_equal 1, purchase.errors[w].length
    end
  end

  # =========================== from part 2 ===========================
  test "when is_applying_plan_change is true on a require_shipping product skips address presence validations on :create" do
    purchase = build_purchase(street_address: nil, full_name: nil, country: nil, state: nil, city: nil, zip_code: nil,
                              link: create_product(require_shipping: true))
    purchase.is_applying_plan_change = true

    assert purchase.valid?
    %i[full_name street_address country state city zip_code].each do |field|
      assert_empty purchase.errors[field]
    end
  end

  test "when is_applying_plan_change is true on a require_shipping product skips address presence validations on :update" do
    purchase = build_purchase(street_address: nil, full_name: nil, country: nil, state: nil, city: nil, zip_code: nil,
                              link: create_product(require_shipping: true))
    purchase.is_updated_original_subscription_purchase = true
    purchase.save!(validate: false)
    purchase.is_applying_plan_change = true

    assert purchase.valid?(:update)
    %i[full_name street_address country state city zip_code].each do |field|
      assert_empty purchase.errors[field]
    end
  end

  # ---- limiting # of sales for a link -----------------------------------------

  test "limiting # of sales for a link no purchases exist increments purchase count" do
    link = create_product(max_purchase_count: 1)
    assert_difference -> { Purchase.count }, 1 do
      create_purchase(link:)
    end
  end

  test "limiting # of sales for a link max purchase limit reached purchase limit is then raised increments count" do
    link = create_product(max_purchase_count: 10)
    create_purchase(link:)
    assert_difference -> { Purchase.count }, 1 do
      create_purchase_2(link:)
    end
  end

  # ---- affiliate_merchant_account ---------------------------------------------

  test "affiliate_merchant_account purchase is on a Gumroad merchant account returns a Gumroad merchant account" do
    purchase = create_purchase
    assert_nil purchase.affiliate_merchant_account.user_id
  end

  test "affiliate_merchant_account purchase is on a Gumroad merchant account returns a merchant account that matches the charge processor of the purchase" do
    purchase = create_purchase
    assert_equal purchase.charge_processor_id, purchase.affiliate_merchant_account.charge_processor_id
  end

  test "affiliate_merchant_account purchase is on a creator's merchant account returns a Gumroad merchant account" do
    purchase = create_purchase(merchant_account: create_merchant_account(charge_processor_merchant_id: "acct_#{unique_suffix}"))
    assert_nil purchase.affiliate_merchant_account.user_id
  end

  test "affiliate_merchant_account purchase is on a creator's merchant account returns a merchant account that matches the charge processor of the purchase" do
    purchase = create_purchase(merchant_account: create_merchant_account(charge_processor_merchant_id: "acct_#{unique_suffix}"))
    assert_equal purchase.charge_processor_id, purchase.affiliate_merchant_account.charge_processor_id
  end

  # ---- tax_label --------------------------------------------------------------

  test "tax_label GST when include_tax_rate is true returns GST with percentage for Australia" do
    rate = create_zip_tax_rate(country: "AU", combined_rate: 0.1)
    purchase = create_purchase(price_cents: 100, total_transaction_cents: 110, gumroad_tax_cents: 10, zip_tax_rate: rate)
    assert_equal "GST (10%)", purchase.tax_label
  end

  test "tax_label GST when include_tax_rate is true returns GST with percentage for Singapore" do
    rate = create_zip_tax_rate(country: "SG", combined_rate: 0.07)
    purchase = create_purchase(price_cents: 100, total_transaction_cents: 107, gumroad_tax_cents: 7, zip_tax_rate: rate)
    assert_equal "GST (7%)", purchase.tax_label
  end

  test "tax_label GST when include_tax_rate is false returns GST without percentage" do
    au = create_zip_tax_rate(country: "AU", combined_rate: 0.1)
    sg = create_zip_tax_rate(country: "SG", combined_rate: 0.07)
    purchase_au = create_purchase(price_cents: 100, total_transaction_cents: 110, gumroad_tax_cents: 10, zip_tax_rate: au)
    purchase_sg = create_purchase(price_cents: 100, total_transaction_cents: 107, gumroad_tax_cents: 7, zip_tax_rate: sg)
    assert_equal "GST", purchase_au.tax_label(include_tax_rate: false)
    assert_equal "GST", purchase_sg.tax_label(include_tax_rate: false)
  end

  test "tax_label VAT when include_tax_rate is true returns VAT with percentage for EU countries" do
    rate = create_zip_tax_rate(country: "DE", combined_rate: 0.19)
    purchase = create_purchase(price_cents: 100, total_transaction_cents: 119, gumroad_tax_cents: 19, zip_tax_rate: rate)
    assert_equal "VAT (19%)", purchase.tax_label
  end

  test "tax_label VAT when include_tax_rate is true returns VAT with percentage for Norway" do
    rate = create_zip_tax_rate(country: "NO", combined_rate: 0.25)
    purchase = create_purchase(price_cents: 100, total_transaction_cents: 125, gumroad_tax_cents: 25, zip_tax_rate: rate)
    assert_equal "VAT (25%)", purchase.tax_label
  end

  test "tax_label VAT when include_tax_rate is true returns VAT with percentage for countries that collect tax on all products" do
    rate = create_zip_tax_rate(country: "JP", combined_rate: 0.1)
    purchase = create_purchase(price_cents: 100, total_transaction_cents: 110, gumroad_tax_cents: 10, zip_tax_rate: rate)
    assert_equal "VAT (10%)", purchase.tax_label
  end

  test "tax_label VAT when include_tax_rate is true returns VAT with percentage for countries that collect tax on digital products" do
    rate = create_zip_tax_rate(country: "BY", combined_rate: 0.2)
    purchase = create_purchase(price_cents: 100, total_transaction_cents: 120, gumroad_tax_cents: 20, zip_tax_rate: rate)
    assert_equal "VAT (20%)", purchase.tax_label
  end

  test "tax_label VAT when include_tax_rate is true rounds down the percentage" do
    rate = create_zip_tax_rate(country: "DE", combined_rate: 0.196)
    purchase = create_purchase(price_cents: 100, total_transaction_cents: 119, gumroad_tax_cents: 19, zip_tax_rate: rate)
    assert_equal "VAT (19%)", purchase.tax_label
  end

  test "tax_label VAT when include_tax_rate is false returns VAT without percentage" do
    eu = create_purchase(price_cents: 100, total_transaction_cents: 119, gumroad_tax_cents: 19, zip_tax_rate: create_zip_tax_rate(country: "DE", combined_rate: 0.19))
    norway = create_purchase(price_cents: 100, total_transaction_cents: 125, gumroad_tax_cents: 25, zip_tax_rate: create_zip_tax_rate(country: "NO", combined_rate: 0.25))
    japan = create_purchase(price_cents: 100, total_transaction_cents: 110, gumroad_tax_cents: 10, zip_tax_rate: create_zip_tax_rate(country: "JP", combined_rate: 0.1))
    digital = create_purchase(price_cents: 100, total_transaction_cents: 120, gumroad_tax_cents: 20, zip_tax_rate: create_zip_tax_rate(country: "BY", combined_rate: 0.2))
    assert_equal "VAT", eu.tax_label(include_tax_rate: false)
    assert_equal "VAT", norway.tax_label(include_tax_rate: false)
    assert_equal "VAT", japan.tax_label(include_tax_rate: false)
    assert_equal "VAT", digital.tax_label(include_tax_rate: false)
  end

  test "tax_label Sales tax when include_tax_rate is true and was_tax_excluded_from_price is true returns 'Sales tax' for US" do
    rate = create_zip_tax_rate(country: "US", combined_rate: 0.08)
    purchase = create_purchase(price_cents: 108, total_transaction_cents: 108, tax_cents: 8, zip_tax_rate: rate, was_tax_excluded_from_price: true)
    assert_equal "Sales tax", purchase.tax_label
  end

  test "tax_label Sales tax when include_tax_rate is true and was_tax_excluded_from_price is true returns 'Sales tax' for Canada" do
    rate = create_zip_tax_rate(country: "CA", combined_rate: 0.13)
    purchase = create_purchase(price_cents: 113, total_transaction_cents: 113, tax_cents: 13, zip_tax_rate: rate, was_tax_excluded_from_price: true)
    assert_equal "Sales tax", purchase.tax_label
  end

  test "tax_label Sales tax when include_tax_rate is true and was_tax_excluded_from_price is true returns 'Sales tax' for other countries" do
    rate = create_zip_tax_rate(country: "BR", combined_rate: 0.15)
    purchase = create_purchase(price_cents: 115, total_transaction_cents: 115, tax_cents: 15, zip_tax_rate: rate, was_tax_excluded_from_price: true)
    assert_equal "Sales tax", purchase.tax_label
  end

  test "tax_label Sales tax when include_tax_rate is true and was_tax_excluded_from_price is false returns 'Sales tax (included)' for US" do
    rate = create_zip_tax_rate(country: "US", combined_rate: 0.08)
    purchase = create_purchase(price_cents: 100, total_transaction_cents: 100, tax_cents: 8, zip_tax_rate: rate, was_tax_excluded_from_price: false)
    assert_equal "Sales tax (included)", purchase.tax_label
  end

  test "tax_label Sales tax when include_tax_rate is true and was_tax_excluded_from_price is false returns 'Sales tax (included)' for Canada" do
    rate = create_zip_tax_rate(country: "CA", combined_rate: 0.13)
    purchase = create_purchase(price_cents: 100, total_transaction_cents: 100, tax_cents: 13, zip_tax_rate: rate, was_tax_excluded_from_price: false)
    assert_equal "Sales tax (included)", purchase.tax_label
  end

  test "tax_label Sales tax when include_tax_rate is true and was_tax_excluded_from_price is false returns 'Sales tax (included)' for other countries" do
    rate = create_zip_tax_rate(country: "BR", combined_rate: 0.15)
    purchase = create_purchase(price_cents: 100, total_transaction_cents: 100, tax_cents: 15, zip_tax_rate: rate, was_tax_excluded_from_price: false)
    assert_equal "Sales tax (included)", purchase.tax_label
  end

  test "tax_label Sales tax when include_tax_rate is false returns 'Sales tax' regardless of was_tax_excluded_from_price" do
    us = create_zip_tax_rate(country: "US", combined_rate: 0.08)
    included_purchase = create_purchase(price_cents: 100, total_transaction_cents: 100, tax_cents: 8, zip_tax_rate: us, was_tax_excluded_from_price: false)
    excluded_purchase = create_purchase(price_cents: 108, total_transaction_cents: 108, tax_cents: 8, zip_tax_rate: us, was_tax_excluded_from_price: true)
    assert_equal "Sales tax", included_purchase.tax_label(include_tax_rate: false)
    assert_equal "Sales tax", excluded_purchase.tax_label(include_tax_rate: false)
  end

  test "tax_label edge cases returns nil when has_tax_label? is false" do
    purchase = create_purchase(price_cents: 100, total_transaction_cents: 100, was_purchase_taxable: false, gumroad_tax_cents: 0, tax_cents: 0)
    assert_nil purchase.tax_label
  end

  test "tax_label edge cases defaults to 'Sales tax (included)' when zip_tax_rate is nil" do
    purchase = create_purchase(price_cents: 100, total_transaction_cents: 120, gumroad_tax_cents: 20, zip_tax_rate: nil)
    assert_equal "Sales tax (included)", purchase.tax_label
  end

  test "tax_label edge cases uses tax_cents when gumroad_tax_cents is 0" do
    rate = create_zip_tax_rate(country: "DE", combined_rate: 0.19)
    purchase = create_purchase(price_cents: 100, total_transaction_cents: 119, gumroad_tax_cents: 0, tax_cents: 19, zip_tax_rate: rate, was_purchase_taxable: true)
    assert_equal "VAT (19%)", purchase.tax_label
  end

  # ---- tax_label_with_creator_tax_info ----------------------------------------

  test "tax_label_with_creator_tax_info purchase without any tax rate attached to it defers to #tax_label" do
    purchase = create_purchase
    purchase.expects(:tax_label)
    purchase.tax_label_with_creator_tax_info
  end

  test "tax_label_with_creator_tax_info purchase without any tax rate attached to it returns nil" do
    purchase = create_purchase
    assert_nil purchase.tax_label_with_creator_tax_info
  end

  test "tax_label_with_creator_tax_info purchase with zip tax rate without an user association defers to #tax_label" do
    zip_tax_rate = create_zip_tax_rate
    purchase = create_purchase(gumroad_tax_cents: 100)
    zip_tax_rate.purchases << purchase
    zip_tax_rate.save!
    purchase.expects(:tax_label)
    purchase.tax_label_with_creator_tax_info
  end

  test "tax_label_with_creator_tax_info purchase with zip tax rate without an user association returns #tax_label's result" do
    zip_tax_rate = create_zip_tax_rate
    purchase = create_purchase(gumroad_tax_cents: 100)
    zip_tax_rate.purchases << purchase
    zip_tax_rate.save!
    assert_equal purchase.tax_label, purchase.tax_label_with_creator_tax_info
  end

  test "tax_label_with_creator_tax_info purchase with zip tax rate with a user association but no invoice_sales_tax_id defers to #tax_label" do
    zip_tax_rate = create_zip_tax_rate
    purchase = create_purchase(tax_cents: 100)
    zip_tax_rate.purchases << purchase
    zip_tax_rate.save!
    zip_tax_rate.user_id = create_user.id
    zip_tax_rate.save!
    purchase.reload
    purchase.expects(:tax_label)
    purchase.tax_label_with_creator_tax_info
  end

  test "tax_label_with_creator_tax_info purchase with zip tax rate with a user association but no invoice_sales_tax_id returns #tax_label's result" do
    zip_tax_rate = create_zip_tax_rate
    purchase = create_purchase(tax_cents: 100)
    zip_tax_rate.purchases << purchase
    zip_tax_rate.save!
    zip_tax_rate.user_id = create_user.id
    zip_tax_rate.save!
    purchase.reload
    assert_equal purchase.tax_label, purchase.tax_label_with_creator_tax_info
  end

  test "tax_label_with_creator_tax_info purchase with zip tax rate with a user association and invoice_sales_tax_id appends the tax ID to the tax_label result" do
    zip_tax_rate = create_zip_tax_rate
    purchase = create_purchase(gumroad_tax_cents: 100)
    zip_tax_rate.purchases << purchase
    zip_tax_rate.save!
    zip_tax_rate.user_id = create_user.id
    zip_tax_rate.invoice_sales_tax_id = "dummy tax ID"
    zip_tax_rate.save!
    purchase.reload
    expected_tax_label = purchase.tax_label + " (Creator tax ID: #{purchase.zip_tax_rate.invoice_sales_tax_id})"
    assert_equal expected_tax_label, purchase.tax_label_with_creator_tax_info
  end

  # ---- #sync_status_with_charge_processor -------------------------------------

  test "#sync_status_with_charge_processor calls Purchase::SyncStatusWithChargeProcessorService for the purchase" do
    purchase = create_purchase
    service = mock("sync_status_service")
    service.expects(:perform)
    Purchase::SyncStatusWithChargeProcessorService.expects(:new).with(purchase, mark_as_failed: true).returns(service)
    purchase.sync_status_with_charge_processor(mark_as_failed: true)
  end

  # ---- #find_enabled_integration ----------------------------------------------

  test "#find_enabled_integration returns the enabled integration for a standalone product purchase" do
    discord_integration = create_discord_integration
    circle_integration = create_circle_integration
    product = create_product
    product.active_integrations << [discord_integration, circle_integration]
    purchase = create_purchase(link: product)

    assert_equal discord_integration, purchase.find_enabled_integration(Integration::DISCORD)
  end

  test "#find_enabled_integration returns the enabled integration for a variant purchase" do
    discord_integration = create_discord_integration
    circle_integration = create_circle_integration
    product = create_product_with_digital_versions
    product.active_integrations << [discord_integration, circle_integration]
    variant = product.variant_categories_alive.first.variants.first
    variant.active_integrations << [discord_integration, circle_integration]
    purchase = create_purchase(link: product, variant_attributes: [variant])

    assert_equal discord_integration, purchase.find_enabled_integration(Integration::DISCORD)
  end

  test "#find_enabled_integration returns nil if the purchased product has an enabled integration but the variant does not" do
    discord_integration = create_discord_integration
    circle_integration = create_circle_integration
    product = create_product_with_digital_versions
    product.active_integrations << [discord_integration, circle_integration]
    variants = product.variant_categories_alive.first.variants
    variant = variants.first
    variant.active_integrations << [discord_integration, circle_integration]
    purchase = create_purchase(link: product, variant_attributes: [variants.second])

    assert_nil purchase.find_enabled_integration(Integration::DISCORD)
  end

  # ---- #perceived_price_cents -------------------------------------------------

  test "#perceived_price_cents nil can be valid because it wasn't used - mainly used in the view" do
    subject = build_purchase
    subject.perceived_price_cents = nil
    assert subject.valid?
  end

  test "#perceived_price_cents does not match but user set his own price for a customizable link is valid" do
    subject = build_purchase
    subject.link.customizable_price = true
    subject.price_range = 79
    subject.perceived_price_cents = subject.price_cents + 10_00
    assert subject.link.customizable_price?
    assert subject.valid?
  end

  # ---- #variant_extra_cost ----------------------------------------------------

  test "#variant_extra_cost for a purchase with no variants returns 0" do
    purchase = create_purchase(variant_attributes: [])
    assert_equal 0, purchase.variant_extra_cost
  end

  test "#variant_extra_cost for a purchase with variants for a non-tiered membership product sums the variants' price_difference_cents" do
    product = create_product
    category1 = create_variant_category(link: product)
    variant1 = create_variant(variant_category: category1)
    category2 = create_variant_category(link: product)
    variant2 = create_variant(variant_category: category2, price_difference_cents: 1_00)
    category3 = create_variant_category(link: product)
    variant3 = create_variant(variant_category: category3, price_difference_cents: 2_00)
    purchase = create_purchase(link: product, variant_attributes: [variant1, variant2, variant3])

    assert_equal 3_00, purchase.variant_extra_cost
  end

  test "#variant_extra_cost for a purchase with variants for a tiered membership product sums the price cents for the variant prices with the given recurrence" do
    setup_variant_extra_cost_tiered
    assert_equal 50_00, @purchase.variant_extra_cost
  end

  test "#variant_extra_cost for a tiered membership product where a variant doesn't have prices returns 0, regardless of the variant's price_difference_cents" do
    setup_variant_extra_cost_tiered
    @tier.prices.destroy_all
    @tier.update!(price_difference_cents: 2_00)

    assert_equal 0, @purchase.variant_extra_cost
  end

  test "#variant_extra_cost for a tiered membership product where a variant has only rental prices returns 0" do
    setup_variant_extra_cost_tiered
    @tier.prices.each do |price|
      price.is_rental = true
      price.save!
    end

    assert_equal 0, @purchase.variant_extra_cost
  end

  test "#variant_extra_cost for a tiered membership product when existing price has been deleted returns 0 if original_price is not set" do
    setup_variant_extra_cost_tiered
    @yearly_price.mark_deleted!
    @tier.prices.find_by(recurrence: BasePrice::Recurrence::YEARLY).mark_deleted!

    assert_equal 0, @purchase.variant_extra_cost
  end

  test "#variant_extra_cost for a tiered membership product when existing price has been deleted counts the deleted price if original_price is set" do
    setup_variant_extra_cost_tiered
    @yearly_price.mark_deleted!
    @tier.prices.find_by(recurrence: BasePrice::Recurrence::YEARLY).mark_deleted!
    @purchase.original_price = @yearly_price

    assert_equal 50_00, @purchase.variant_extra_cost
  end

  # ---- mass assignment --------------------------------------------------------

  test "mass assignment sets price" do
    assert_equal 1_00, Purchase.new(price_cents: 100).price_cents
  end

  test "mass assignment sets total transaction amount" do
    assert_equal 1_00, Purchase.new(total_transaction_cents: 100).total_transaction_cents
  end

  test "mass assignment sets chargeable" do
    assert_equal ["bogart"], Purchase.new(chargeable: ["bogart"]).chargeable
  end

  test "mass assignment sets perceived price" do
    assert_equal 100, Purchase.new(perceived_price_cents: 100).perceived_price_cents
  end

  # ---- non-subscription -------------------------------------------------------

  test "non-subscription does not schedule recurring charge" do
    purchase = build_purchase(purchase_state: "in_progress")
    purchase.update_balance_and_mark_successful!

    assert_equal 0, RecurringChargeWorker.jobs.size
  end

  # ---- delegation -------------------------------------------------------------

  test "delegation has seller info" do
    # Give the seller a name so the delegation of a real value is exercised (a nameless
    # seller would make both sides nil, which also trips Minitest's assert_nil deprecation).
    subject = create_purchase(link: create_product(user: create_named_seller))
    assert_equal subject.seller.email, subject.seller_email
    assert_equal subject.seller.name, subject.seller_name
  end

  test "delegation has link info" do
    subject = create_purchase
    assert_equal subject.link.name, subject.link_name
  end

  # ---- price_is_not_cheated ---------------------------------------------------

  test "price_is_not_cheated is valid if price is at or above link price" do
    link = create_product(price_cents: 200)
    subject = create_purchase(link:, seller: link.user)

    subject.price_cents = 200
    assert subject.valid?

    subject.price_cents = 300
    assert subject.valid?
  end

  # ---- price_cents ------------------------------------------------------------

  test "price_cents returns the price in cents" do
    subject = create_purchase(price_cents: 1_00)
    assert_equal 100, subject.price_cents
    assert_kind_of Integer, subject.price_cents
  end

  # ---- total_transaction_cents ------------------------------------------------

  test "total_transaction_cents returns the total transaction price in cents" do
    subject = create_purchase(total_transaction_cents: 1_00)
    assert_equal 100, subject.total_transaction_cents
    assert_kind_of Integer, subject.total_transaction_cents
  end

  # ---- fee_cents --------------------------------------------------------------

  test "fee_cents gets calculated on creation" do
    purchase = create_purchase(price_cents: 1_00)
    assert_equal 93, purchase.fee_cents # 10c (10%) + 3c (2.9% cc fee) + 30c (fixed cc fee)

    purchase = create_purchase(price_cents: 2_00)
    assert_equal 106, purchase.fee_cents # 20c (10%) + 50c + 6c (2.9% cc fee) + 30c (fixed cc fee)

    purchase = create_purchase(price_cents: 3_00)
    assert_equal 119, purchase.fee_cents # 30c (10%) + 50c + 9c (2.9% cc fee) + 30c (fixed cc fee)
  end

  test "fee_cents doesn't reset the rate when it gets saved again" do
    purchase = create_purchase(price_cents: 1_00)

    purchase.fee_cents = 20
    purchase.save

    assert_equal 20, purchase.fee_cents
  end

  test "fee_cents is 0 if merchant account is a Brazilian Stripe Connect account" do
    VCR.use_cassette("Purchase/fee_cents/is_0_if_merchant_account_is_a_Brazilian_Stripe_Connect_account") do
      seller = create_named_seller
      product = create_product(price_cents: 10_00, user: seller)
      purchase = create_purchase(link: product,
                                 chargeable: build_chargeable,
                                 merchant_account: create_merchant_account_stripe_connect(user: seller, country: "BR"))
      assert_equal 0, purchase.fee_cents
    end
  end

  # ---- processor_fee_cents ----------------------------------------------------

  test "processor_fee_cents gets calculated correctly" do
    VCR.use_cassette("Purchase/processor_fee_cents/gets_calculated_correctly") do
      purchase = create_purchase
      purchase.perceived_price_cents = 100
      purchase.chargeable = build_chargeable
      purchase.process!
      assert_equal 10, purchase.processor_fee_cents
    end
  end

  # ---- fee_dollars ------------------------------------------------------------

  test "fee_dollars gets calculated correctly" do
    purchase = create_purchase(price_cents: 10_00)
    assert_equal 2.09, purchase.fee_dollars # 100c (10%) + 50c + 29c (2.9% cc fee) + 30c (fixed cc fee)

    purchase = create_purchase(price_cents: 15_00)
    assert_equal 2.74, purchase.fee_dollars # 150c (10%) + 50c + 44c (2.9% cc fee) + 30c (fixed cc fee)

    purchase = create_purchase(price_cents: 22_00)
    assert_equal 3.64, purchase.fee_dollars # 220c (10%) + 50c + 64c (2.9% cc fee) + 30c (fixed cc fee)
  end

  # ---- payment ----------------------------------------------------------------

  test "payment is the difference between price and fee" do
    purchase = create_purchase(price_cents: 1_00)
    assert_equal 7, purchase.payment_cents # calculated fee is 93c -- 10c (10%) + 50c + 3c (2.9% cc fee) + 30c (fixed cc fee)
  end

  # ---- save_with_payment ------------------------------------------------------

  test "save_with_payment doesn't hit stripe if invalid" do
    purchase = build_purchase(link: create_product)
    purchase.process!
    assert purchase.errors[:base].present?
  end

  test "save_with_payment does not hit stripe if user_suspended" do
    user = create_user
    product = create_product(user:)
    user.suspend_for_fraud(author_name: "Admin")
    product.save!
    purchase = build_purchase(link: product)
    purchase.process!
    assert purchase.errors[:base].present?
  end

  test "save_with_payment does not hit stripe if link_disabled" do
    user = create_user
    product = create_product(user:)
    product.purchase_disabled_at = Time.current
    product.save!
    purchase = build_purchase(link: product)
    purchase.process!
    assert purchase.errors[:base].present?
  end

  test "save_with_payment does not hit stripe if link_deleted" do
    user = create_user
    product = create_product(user:)
    product.deleted_at = Time.current
    product.save!
    purchase = build_purchase(link: product)
    purchase.process!
    assert purchase.errors[:base].present?
  end

  # ---- #charged_using_paypal_connect_account? ---------------------------------

  test "#charged_using_paypal_connect_account? returns true if merchant account is a paypal connect account otherwise false" do
    VCR.use_cassette("Purchase/_charged_using_paypal_connect_account_/returns_true_if_merchant_account_is_a_paypal_connect_account_otherwise_false") do
      assert_equal false, create_purchase(merchant_account: create_merchant_account_stripe).charged_using_paypal_connect_account?
      assert_equal false, create_purchase(merchant_account: create_merchant_account_stripe_connect).charged_using_paypal_connect_account?
      assert_equal true, create_purchase(merchant_account: create_merchant_account_paypal).charged_using_paypal_connect_account?
    end
  end

  # ---- new flat fee -----------------------------------------------------------

  test "new flat fee charge on gumroad stripe account uses flat fee if applicable to the creator otherwise uses tier fee" do
    VCR.use_cassette("Purchase/new_flat_fee/charge_on_gumroad_stripe_account/uses_flat_fee_if_applicable_to_the_creator_otherwise_uses_tier_fee") do
      creator = create_user
      product = create_product(user: creator, price_cents: 10_00)
      purchase = create_purchase(link: product, purchase_state: "in_progress", chargeable: build_chargeable)
      purchase.process!

      assert_equal StripeChargeProcessor.charge_processor_id, purchase.charge_processor_id
      assert_equal 209, purchase.fee_cents # 100 (10pc gumroad fee) + 50c + 29 (2.9 pc stripe fee) + 30 (30c fixed stripe fee)
    end
  end

  test "new flat fee charge on a custom stripe connect account uses flat fee if applicable to the creator otherwise uses tier fee" do
    VCR.use_cassette("Purchase/new_flat_fee/charge_on_a_custom_stripe_connect_account/uses_flat_fee_if_applicable_to_the_creator_otherwise_uses_tier_fee") do
      creator = create_user
      product = create_product(user: creator, price_cents: 10_00)
      merchant_account = create_merchant_account(user: creator, charge_processor_merchant_id: "acct_19paZxAQqMpdRp2I")

      purchase = create_purchase(link: product, purchase_state: "in_progress", chargeable: build_chargeable)
      purchase.process!

      assert_equal StripeChargeProcessor.charge_processor_id, purchase.charge_processor_id
      assert_equal merchant_account, purchase.merchant_account
      assert_equal 209, purchase.fee_cents # 100 (10pc gumroad fee) + 50c + 29 (2.9 pc stripe fee) + 30 (30c fixed stripe fee)
    end
  end

  test "new flat fee charge on a paypal connect account uses flat fee if applicable to the creator otherwise uses tier fee" do
    VCR.use_cassette("Purchase/new_flat_fee/charge_on_a_paypal_connect_account/uses_flat_fee_if_applicable_to_the_creator_otherwise_uses_tier_fee") do
      creator = create_user
      product = create_product(user: creator, price_cents: 10_00)
      merchant_account = create_merchant_account_paypal(user: creator, charge_processor_merchant_id: "CJS32DZ7NDN5L", country: "GB", currency: "gbp")

      purchase = create_purchase(link: product, purchase_state: "in_progress", chargeable: build_native_paypal_chargeable)
      purchase.process!

      assert_equal PaypalChargeProcessor.charge_processor_id, purchase.charge_processor_id
      assert_equal merchant_account, purchase.merchant_account
      assert_equal 150, purchase.fee_cents # 100 (10pc gumroad fee) + 50c
    end
  end

  test "new flat fee charge on gumroad paypal account via braintree uses flat fee if applicable to the creator otherwise uses tier fee" do
    VCR.use_cassette("Purchase/new_flat_fee/charge_on_gumroad_paypal_account_via_braintree/uses_flat_fee_if_applicable_to_the_creator_otherwise_uses_tier_fee") do
      creator = create_user
      product = create_product(user: creator, price_cents: 10_00)
      purchase = create_purchase(link: product, purchase_state: "in_progress", chargeable: build_paypal_chargeable)
      purchase.process!

      assert_equal BraintreeChargeProcessor.charge_processor_id, purchase.charge_processor_id
      assert_equal 209, purchase.fee_cents # 100 (10pc gumroad fee) + 50c + 29 (2.9 pc paypal fee) + 30 (30c fixed paypal fee)
    end
  end

  test "new flat fee charges discover fee of 30%" do
    VCR.use_cassette("Purchase/new_flat_fee/charges_discover_fee_of_30_") do
      creator = create_user
      product = create_product(user: creator, price_cents: 10_00)
      product.update!(discover_fee_per_thousand: 500)
      create_user_compliance_info(user: creator)

      stripe_purchase = create_purchase(link: product, purchase_state: "in_progress", was_product_recommended: true, chargeable: build_chargeable)
      stripe_purchase.process!
      assert_equal StripeChargeProcessor.charge_processor_id, stripe_purchase.reload.charge_processor_id
      assert_equal 300, stripe_purchase.fee_cents # flat 30% discover fee

      braintree_purchase = create_purchase(link: product, purchase_state: "in_progress", was_product_recommended: true, chargeable: build_paypal_chargeable)
      braintree_purchase.process!
      assert_equal BraintreeChargeProcessor.charge_processor_id, braintree_purchase.reload.charge_processor_id
      assert_equal 300, braintree_purchase.fee_cents # flat 30% discover fee

      Feature.activate_user(:merchant_migration, creator)
      stripe_connect_account = create_merchant_account_stripe_connect(user: creator)
      stripe_connect_purchase = create_purchase(link: product, purchase_state: "in_progress", was_product_recommended: true, chargeable: build_chargeable(product_permalink: product.unique_permalink))
      stripe_connect_purchase.process!
      assert_equal StripeChargeProcessor.charge_processor_id, stripe_connect_purchase.reload.charge_processor_id
      assert_equal stripe_connect_account, stripe_connect_purchase.merchant_account
      assert_equal 300, stripe_connect_purchase.fee_cents # flat 30% discover fee
      Feature.deactivate_user(:merchant_migration, creator)

      paypal_connect_account = create_merchant_account_paypal(user: creator, charge_processor_merchant_id: "CJS32DZ7NDN5L", country: "GB", currency: "gbp")
      paypal_connect_purchase = create_purchase(link: product, purchase_state: "in_progress", was_product_recommended: true, chargeable: build_native_paypal_chargeable)
      paypal_connect_purchase.process!
      assert_equal PaypalChargeProcessor.charge_processor_id, paypal_connect_purchase.reload.charge_processor_id
      assert_equal paypal_connect_account, paypal_connect_purchase.merchant_account
      assert_equal 300, paypal_connect_purchase.fee_cents # flat 30% discover fee
    end
  end

  # new flat fee / on Gumroad day — behaves_like "charges no Gumroad fee on new sales"

  test "new flat fee on Gumroad day does not charge 10% Gumroad fee for regular product sale" do
    assert_waived_regular_product_sale(setup_gumroad_day_seller)
  end

  test "new flat fee on Gumroad day does not charge 10% Gumroad fee for new membership product sale" do
    assert_waived_new_membership_sale(setup_gumroad_day_seller)
  end

  test "new flat fee on Gumroad day does not charge 10% Gumroad fee for recommended regular product sale" do
    assert_waived_recommended_regular_sale(setup_gumroad_day_seller)
  end

  test "new flat fee on Gumroad day does not charge 10% Gumroad fee for recommended new membership product sale" do
    assert_waived_recommended_new_membership_sale(setup_gumroad_day_seller)
  end

  test "new flat fee on Gumroad day charges the boost fee minus the 10% Gumroad fee for recommended new membership product sale" do
    assert_boost_fee_minus_gumroad_recommended_new_membership(setup_gumroad_day_seller)
  end

  test "new flat fee on Gumroad day charges 10% Gumroad fee for recurring charge on existing membership" do
    assert_gumroad_fee_recurring_existing_membership(setup_gumroad_day_seller)
  end

  test "new flat fee on Gumroad day charges the boost fee including 10% Gumroad fee for recurring charge on recommended membership sale" do
    assert_boost_fee_including_gumroad_recurring_recommended_membership(setup_gumroad_day_seller)
  end

  test "new flat fee on Gumroad day charges 10% Gumroad fee for charge on existing preorder" do
    seller = setup_gumroad_day_seller
    VCR.use_cassette("Purchase/new_flat_fee/on_Gumroad_day/behaves_like_charges_no_Gumroad_fee_on_new_sales/charges_10_Gumroad_fee_for_charge_on_existing_preorder") do
      assert_gumroad_fee_existing_preorder(seller)
    end
  end

  # new flat fee / with waive_gumroad_fee_on_new_sales feature flag set — behaves_like

  test "new flat fee with waive_gumroad_fee_on_new_sales feature flag set does not charge 10% Gumroad fee for regular product sale" do
    assert_waived_regular_product_sale(setup_waive_feature_seller)
  end

  test "new flat fee with waive_gumroad_fee_on_new_sales feature flag set does not charge 10% Gumroad fee for new membership product sale" do
    assert_waived_new_membership_sale(setup_waive_feature_seller)
  end

  test "new flat fee with waive_gumroad_fee_on_new_sales feature flag set does not charge 10% Gumroad fee for recommended regular product sale" do
    assert_waived_recommended_regular_sale(setup_waive_feature_seller)
  end

  test "new flat fee with waive_gumroad_fee_on_new_sales feature flag set does not charge 10% Gumroad fee for recommended new membership product sale" do
    assert_waived_recommended_new_membership_sale(setup_waive_feature_seller)
  end

  test "new flat fee with waive_gumroad_fee_on_new_sales feature flag set charges the boost fee minus the 10% Gumroad fee for recommended new membership product sale" do
    assert_boost_fee_minus_gumroad_recommended_new_membership(setup_waive_feature_seller)
  end

  test "new flat fee with waive_gumroad_fee_on_new_sales feature flag set charges 10% Gumroad fee for recurring charge on existing membership" do
    assert_gumroad_fee_recurring_existing_membership(setup_waive_feature_seller)
  end

  test "new flat fee with waive_gumroad_fee_on_new_sales feature flag set charges the boost fee including 10% Gumroad fee for recurring charge on recommended membership sale" do
    assert_boost_fee_including_gumroad_recurring_recommended_membership(setup_waive_feature_seller)
  end

  test "new flat fee with waive_gumroad_fee_on_new_sales feature flag set charges 10% Gumroad fee for charge on existing preorder" do
    seller = setup_waive_feature_seller
    VCR.use_cassette("Purchase/new_flat_fee/with_waive_gumroad_fee_on_new_sales_feature_flag_set/behaves_like_charges_no_Gumroad_fee_on_new_sales/charges_10_Gumroad_fee_for_charge_on_existing_preorder") do
      assert_gumroad_fee_existing_preorder(seller)
    end
  end

  # ---- purchase requires either purchaser or email ----------------------------

  test "purchase requires either purchaser or email works with a purchaser" do
    user = create_user
    purchase = build_purchase(purchaser: user)
    assert purchase.valid?
  end

  test "purchase requires either purchaser or email works with an email" do
    purchase = build_purchase(email: "test@example.com")
    assert purchase.valid?
  end

  test "purchase requires either purchaser or email is not valid without either" do
    purchase = build_purchase(email: nil)
    assert_not purchase.valid?
  end

  # ---- create_url_redirect! ---------------------------------------------------

  test "create_url_redirect! doesn't create it multiple times, even if called a bunch" do
    VCR.use_cassette("Purchase/create_url_redirect_/doesn_t_create_it_multiple_times_even_if_called_a_bunch") do
      setup_create_url_redirect_outer
      assert_difference -> { UrlRedirect.count }, 1 do
        @purchase.create_url_redirect!
        @purchase.create_url_redirect!
        @purchase.create_url_redirect!
      end
    end
  end

  test "create_url_redirect! commission completion purchase does not create a url redirect" do
    VCR.use_cassette("Purchase/create_url_redirect_/commission_completion_purchase/does_not_create_a_url_redirect") do
      setup_create_url_redirect_outer
      purchase = create_purchase(is_commission_completion_purchase: true)
      purchase.create_url_redirect!
      assert_nil purchase.url_redirect
    end
  end

  test "create_url_redirect! subscriptions has past installments sends the last installment as an email to the new subscriber" do
    VCR.use_cassette("Purchase/create_url_redirect_/subscriptions/has_past_installments/sends_the_last_installment_as_an_email_to_the_new_subscriber") do
      setup_create_url_redirect_subscriptions
      @subscription.purchases << @purchase
      @purchase.update_balance_and_mark_successful!

      assert SendLastPostJob.jobs.any? { |job| job["args"] == [@purchase.id] }
    end
  end

  test "create_url_redirect! subscriptions has past installments does not send the last installment to the subscriber on recurring charges" do
    VCR.use_cassette("Purchase/create_url_redirect_/subscriptions/has_past_installments/does_not_send_the_last_installment_to_the_subscriber_on_recurring_charges") do
      setup_create_url_redirect_subscriptions
      create_installment(link: @product, published_at: Time.current)

      @subscription.purchases << @purchase
      @purchase.update_balance_and_mark_successful!

      SendLastPostJob.jobs.clear

      recurring_purchase = create_purchase(seller: @user, purchase_state: "in_progress", subscription: @subscription, link: @product)
      recurring_purchase.update_balance_and_mark_successful!

      assert_equal 0, SendLastPostJob.jobs.size
    end
  end

  test "create_url_redirect! subscriptions has past installments subscription should not send last update does not send the last installment to the new subscriber" do
    VCR.use_cassette("Purchase/create_url_redirect_/subscriptions/has_past_installments/subscription_should_not_send_last_update/does_not_send_the_last_installment_to_the_new_subscriber") do
      setup_create_url_redirect_subscriptions
      @product.update_attribute(:should_include_last_post, false)

      @subscription.purchases << @purchase
      @purchase.update_balance_and_mark_successful!

      assert_equal 0, SendLastPostJob.jobs.size
    end
  end

  test "create_url_redirect! non-webhook product creates a url_redirect" do
    VCR.use_cassette("Purchase/create_url_redirect_/non-webhook_product/creates_a_url_redirect") do
      setup_create_url_redirect_outer
      product = create_product
      purchase = create_purchase(link: product)
      assert_difference -> { UrlRedirect.count }, 1 do
        purchase.create_url_redirect!
      end
    end
  end

  # ---- financial_transaction_valid? -------------------------------------------

  test "financial_transaction_valid? has charge processor details if amount not 0" do
    p = create_purchase(email: "email@email.email", purchase_state: "in_progress")

    p.stripe_fingerprint = "some-fingerprint"
    p.stripe_transaction_id = nil
    p.charge_processor_id = nil
    assert_equal false, p.mark_successful

    p.stripe_fingerprint = nil
    p.stripe_transaction_id = "some-value"
    p.charge_processor_id = nil
    assert_equal false, p.mark_successful

    p.stripe_fingerprint = nil
    p.stripe_transaction_id = nil
    p.charge_processor_id = "some-processor"
    assert_equal false, p.mark_successful

    p.stripe_fingerprint = "some-fingerprint"
    p.stripe_transaction_id = "some-value"
    p.charge_processor_id = nil
    assert_equal false, p.mark_successful

    p.stripe_fingerprint = "some-fingerprint"
    p.stripe_transaction_id = nil
    p.charge_processor_id = "some-processor"
    assert_equal false, p.mark_successful

    p.stripe_fingerprint = nil
    p.stripe_transaction_id = "some-value"
    p.charge_processor_id = "some-processor"
    assert_equal false, p.mark_successful

    p.stripe_transaction_id = nil
    p.stripe_fingerprint = nil
    p.charge_processor_id = nil
    assert_equal false, p.mark_successful

    p.stripe_fingerprint = "some-fingerprint"
    p.stripe_transaction_id = "some-value"
    p.charge_processor_id = "some-processor"
    assert_equal true, p.mark_successful
  end

  test "financial_transaction_valid? does not update with charge processor details if amount = 0" do
    link = create_product(price_range: "$0+")
    p = create_purchase(link:, seller: link.user, email: "email@email.email", purchase_state: "in_progress")
    p.price_cents = 0

    p.stripe_fingerprint = "some-fingerprint"
    p.stripe_transaction_id = nil
    p.charge_processor_id = nil
    assert_equal false, p.mark_successful

    p.stripe_fingerprint = nil
    p.stripe_transaction_id = "some-value"
    p.charge_processor_id = nil
    assert_equal false, p.mark_successful

    p.stripe_fingerprint = nil
    p.stripe_transaction_id = nil
    p.charge_processor_id = "some-processor"
    assert_equal false, p.mark_successful

    p.stripe_fingerprint = "some-fingerprint"
    p.stripe_transaction_id = "some-value"
    p.charge_processor_id = nil
    assert_equal false, p.mark_successful

    p.stripe_fingerprint = "some-fingerprint"
    p.stripe_transaction_id = nil
    p.charge_processor_id = "some-processor"
    assert_equal false, p.mark_successful

    p.stripe_fingerprint = nil
    p.stripe_transaction_id = "some-value"
    p.charge_processor_id = "some-processor"
    assert_equal false, p.mark_successful

    p.stripe_fingerprint = "some-fingerprint"
    p.stripe_transaction_id = "some-value"
    p.charge_processor_id = "some-processor"
    assert_equal false, p.mark_successful

    p.stripe_transaction_id = nil
    p.stripe_fingerprint = nil
    p.charge_processor_id = nil
    p.merchant_account = nil
    assert_equal true, p.mark_successful
  end

  # ---- merchant account -------------------------------------------------------

  test "merchant account when the creator does not have their own merchant account is charged using a Gumroad merchant account for suppliers" do
    VCR.use_cassette("Purchase/merchant_account/when_the_creator_does_not_have_their_own_merchant_account/is_charged_using_a_Gumroad_merchant_account_for_suppliers") do
      user = create_user
      link = create_product(user:, is_physical: false, require_shipping: false, shipping_destinations: [])
      chargeable = build_chargeable
      purchase = build_merchant_account_purchase(user:, link:, chargeable:)
      purchase.save!
      purchase.process!
      assert_empty purchase.errors
      assert_equal MerchantAccount.gumroad(purchase.charge_processor_id), purchase.merchant_account
    end
  end

  test "merchant account when the creator has their own merchant account when the link is digital is charged using the creators merchant account" do
    VCR.use_cassette("Purchase/merchant_account/when_the_creator_has_their_own_merchant_account/when_the_link_is_digital/is_charged_using_the_creators_merchant_account") do
      user = create_user
      merchant_account = create_merchant_account_stripe(user:)
      user.reload
      link = create_product(user:, is_physical: false, require_shipping: false, shipping_destinations: [])
      chargeable = build_chargeable
      purchase = build_merchant_account_purchase(user:, link:, chargeable:)
      purchase.save!
      purchase.process!
      assert_empty purchase.errors
      assert_equal merchant_account, purchase.merchant_account
    end
  end

  test "merchant account when the creator has their own merchant account when the link is physical is charged using the creators merchant account" do
    VCR.use_cassette("Purchase/merchant_account/when_the_creator_has_their_own_merchant_account/when_the_link_is_physical/is_charged_using_the_creators_merchant_account") do
      user = create_user
      create_merchant_account_stripe(user:)
      user.reload
      link = create_product(user:, is_physical: true, require_shipping: true, shipping_destinations: [build_shipping_destination])
      chargeable = build_chargeable
      purchase = build_merchant_account_purchase(user:, link:, chargeable:)
      purchase.save!
      purchase.process!
      assert_empty purchase.errors
      assert_equal user.merchant_account(purchase.charge_processor_id), purchase.merchant_account
    end
  end

  test "merchant account when the creator has their own merchant account when the purchase has sales tax that gumroad is collecting and will pay as the merchant is charged using a Gumroad merchant account for suppliers" do
    VCR.use_cassette("Purchase/merchant_account/when_the_creator_has_their_own_merchant_account/when_the_purchase_has_sales_tax_that_gumroad_is_collecting_and_will_pay_as_the_merchant/is_charged_using_a_Gumroad_merchant_account_for_suppliers") do
      user = create_user
      merchant_account = create_merchant_account_stripe(user:)
      user.reload
      link = create_product(user:, is_physical: false, require_shipping: false, shipping_destinations: [])
      chargeable = build_chargeable
      chargeable.stubs(:country).returns(Compliance::Countries::GBR.alpha2)
      create_zip_tax_rate(zip_code: nil, state: nil, country: Compliance::Countries::GBR.alpha2, combined_rate: 1.0, is_seller_responsible: false)
      purchase = create_purchase(seller: user, link:, price_cents: link.price_cents, fee_cents: 30, purchase_state: "in_progress", merchant_account: nil, chargeable:,
                                 full_name: "Edgar Gumstein", street_address: "123 Gum Road", city: "London", zip_code: "94017", country: "United Kingdom", ip_country: "United Kingdom")
      purchase.process!
      assert_empty purchase.errors
      assert_equal merchant_account, purchase.merchant_account
    end
  end

  # =========================== from part 3 ===========================
  test "not_double_charged allows double charges with bundle product purchases" do
    product = create_product
    ip = unique_ip
    create_purchase(link: product, seller: product.user, email: "bob@gumroad.com", ip_address: ip, created_at: Time.current)
    purchase2 = build_purchase(link: product, email: "bob@gumroad.com", ip_address: ip, created_at: Time.current, is_bundle_product_purchase: true)
    assert purchase2.valid?
  end

  test "not_double_charged disallows double-charges to the same email and IP address" do
    product = create_product
    ip = unique_ip
    purchase1 = create_purchase(link: product, seller: product.user, email: "bob@gumroad.com", ip_address: ip, created_at: Time.current)
    purchase2 = build_purchase(link: product, email: "bob@gumroad.com", ip_address: ip, created_at: Time.current)
    assert_not_equal purchase1.id, purchase2.id
    assert_not purchase2.valid?
  end

  test "not_double_charged allows double-charges to different IP addresses" do
    product = create_product
    ip = unique_ip
    create_purchase(link: product, seller: product.user, email: "bob@gumroad.com", ip_address: ip, created_at: Time.current)
    purchase2 = build_purchase(link: product, email: "bob2@gumroad.com", created_at: Time.current)
    assert purchase2.valid?
  end

  test "not_double_charged disallows double-charges if the first purchase is in progress" do
    product = create_product
    ip = unique_ip
    purchase1 = create_purchase(link: product, seller: product.user, email: "bob@gumroad.com", ip_address: ip, created_at: Time.current, purchase_state: "in_progress")
    purchase2 = build_purchase(link: product, email: "bob@gumroad.com", ip_address: ip, created_at: Time.current)
    assert_not_equal purchase1.id, purchase2.id
    assert_not purchase2.valid?
  end

  test "not_double_charged allows double-charges after 5 min" do
    product = create_product
    ip = unique_ip
    create_purchase(link: product, seller: product.user, email: "bob@gumroad.com", ip_address: ip, created_at: 6.minutes.ago)
    purchase2 = build_purchase(link: product, email: "bob@gumroad.com", ip_address: ip, created_at: Time.current)
    assert purchase2.valid?
  end

  test "not_double_charged allows double-charge if purchase is marked as automatic" do
    product = create_product
    ip = unique_ip
    create_purchase(link: product, seller: product.user, ip_address: ip, email: "tweeter@gumroad.com", created_at: Time.current)
    purchase2 = build_purchase(link: product, ip_address: ip, email: "tweeter@gumroad.com", created_at: Time.current)
    purchase2.is_automatic_charge = true
    assert purchase2.valid?
  end

  test "not_double_charged allows double-charge if purchase is from the profile page and of a quantity-enabled product" do
    product = create_physical_product(quantity_enabled: true)
    ip = unique_ip
    create_physical_purchase(link: product, seller: product.user, ip_address: ip, email: "bob@gumroad.com", created_at: Time.current)
    purchase2 = build_physical_purchase(link: product, ip_address: ip, email: "bob@gumroad.com", created_at: Time.current)
    purchase2.is_multi_buy = true
    purchase2.variant_attributes << product.skus.is_default_sku.first
    assert purchase2.valid?
  end

  # context "when gifting"
  test "not_double_charged when gifting as first product purchase allows the gift-purchase" do
    travel_to(Time.current)
    ip = unique_ip
    product = create_product
    giftee_email = "giftee-#{unique_suffix}@example.com"
    gift = create_gift(giftee_email:)
    gifter_email = "gifter-#{unique_suffix}@example.com"

    purchase_given = build_purchase(link: product, gift_given: gift, is_gift_sender_purchase: true, ip_address: ip, email: gifter_email)
    purchase_given.send(:not_double_charged)
    assert purchase_given.valid?

    purchase_received = build_purchase(link: product, gift_received: gift, is_gift_receiver_purchase: true, ip_address: ip, email: giftee_email)
    purchase_received.send(:not_double_charged)
    assert purchase_received.valid?
  end

  test "not_double_charged when gifting after purchasing it as a non-gift allows the gift-purchase" do
    travel_to(Time.current)
    ip = unique_ip
    user = create_user
    product = create_product
    giftee_email = "giftee-#{unique_suffix}@example.com"
    gift = create_gift(giftee_email:)
    gifter_email = "gifter-#{unique_suffix}@example.com"
    create_purchase(link: product)

    purchase_given = build_purchase(link: product, gift_given: gift, purchaser: user, is_gift_sender_purchase: true, ip_address: ip, email: gifter_email)
    purchase_given.send(:not_double_charged)
    assert purchase_given.valid?

    purchase_received = build_purchase(link: product, gift_received: gift, is_gift_receiver_purchase: true, ip_address: ip, email: giftee_email)
    purchase_received.send(:not_double_charged)
    assert purchase_received.valid?
  end

  test "not_double_charged when gifting after gifting to someone else allows the gift-purchase" do
    travel_to(Time.current)
    ip = unique_ip
    user = create_user
    product = create_product
    giftee_email = "giftee-#{unique_suffix}@example.com"
    gift = create_gift(giftee_email:)
    create_purchase(link: product, gift_given: gift, purchaser: user, is_gift_sender_purchase: true, ip_address: ip, email: user.email)

    second_giftee_email = "giftee2-#{unique_suffix}@example.com"
    second_gift = create_gift(giftee_email: second_giftee_email)

    purchase_given = build_purchase(link: product, gift_given: second_gift, purchaser: user, is_gift_sender_purchase: true, ip_address: ip, email: user.email)
    purchase_given.send(:not_double_charged)
    assert purchase_given.valid?

    purchase_received = build_purchase(link: product, gift_received: second_gift, is_gift_receiver_purchase: true, ip_address: ip, email: second_giftee_email)
    purchase_received.send(:not_double_charged)
    assert purchase_received.valid?
  end

  test "not_double_charged when gifting after gifting to someone else allows purchase as a non-gift to original purchaser" do
    travel_to(Time.current)
    ip = unique_ip
    user = create_user
    product = create_product
    giftee_email = "giftee-#{unique_suffix}@example.com"
    gift = create_gift(giftee_email:)
    create_purchase(link: product, gift_given: gift, purchaser: user, is_gift_sender_purchase: true, ip_address: ip, email: user.email)

    purchase = build_purchase(link: product, purchaser: user, email: user.email, ip_address: ip)
    purchase.send(:not_double_charged)
    assert purchase.valid?
  end

  test "not_double_charged when gifting a subscription disallows double-charges to the same email and IP address" do
    travel_to(Time.current)
    ip = unique_ip
    user = create_user
    product = create_product
    giftee_email = "giftee-#{unique_suffix}@example.com"
    gift = create_gift(giftee_email:)
    original_purchase = create_membership_purchase(link: product, gift_given: gift, purchaser: user, is_gift_sender_purchase: true, email: user.email, ip_address: ip, subscription: create_subscription)

    purchase = build_membership_purchase_p3(link: product, email: gift.giftee_email, ip_address: ip, created_at: Time.current)
    assert_not_equal original_purchase.id, purchase.id
    assert_not purchase.valid?
    assert_equal ["You have already paid for this product. It has been emailed to you."], purchase.errors[:base]
  end

  test "not_double_charged when gifting a subscription allows the recurring charge" do
    travel_to(Time.current)
    ip = unique_ip
    user = create_user
    product = create_product
    giftee_email = "giftee-#{unique_suffix}@example.com"
    gift = create_gift(giftee_email:)
    original_purchase = create_membership_purchase(link: product, gift_given: gift, purchaser: user, is_gift_sender_purchase: true, email: user.email, ip_address: ip, subscription: create_subscription)

    purchase = build_recurring_membership_purchase(link: original_purchase.link, subscription: original_purchase.subscription, purchaser: user, email: giftee_email)
    assert purchase.valid?
  end

  # context "when an earlier purchase's payment is still settling"
  test "not_double_charged settling disallows a repeat purchase while a confirmed payment is settling even outside the recent-purchase window" do
    product = create_product
    ip = unique_ip
    create_purchase(link: product, seller: product.user, email: "bob@gumroad.com", ip_address: ip,
                    purchase_state: "in_progress", stripe_status: "processing", created_at: 2.days.ago)
    purchase2 = build_purchase(link: product, email: "bob@gumroad.com", ip_address: ip, created_at: Time.current)
    assert_not purchase2.valid?
    assert_equal ["Your previous payment for this product is still processing. We will email you a receipt as soon as it completes — please do not pay again."], purchase2.errors[:base]
  end

  test "not_double_charged settling disallows the repeat purchase from a different IP address" do
    product = create_product
    ip = unique_ip
    create_purchase(link: product, seller: product.user, email: "bob@gumroad.com", ip_address: ip,
                    purchase_state: "in_progress", stripe_status: "processing", created_at: 1.day.ago)
    purchase2 = build_purchase(link: product, email: "bob@gumroad.com", ip_address: unique_ip, created_at: Time.current)
    assert_not purchase2.valid?
  end

  test "not_double_charged settling allows a repeat purchase when the earlier attempt was abandoned before payment confirmation" do
    product = create_product
    ip = unique_ip
    create_purchase(link: product, seller: product.user, email: "bob@gumroad.com", ip_address: ip,
                    purchase_state: "in_progress", stripe_status: nil, created_at: 1.hour.ago)
    purchase2 = build_purchase(link: product, email: "bob@gumroad.com", ip_address: ip, created_at: Time.current)
    assert purchase2.valid?
  end

  test "not_double_charged settling allows a repeat purchase once the earlier attempt has failed" do
    product = create_product
    ip = unique_ip
    create_purchase(link: product, seller: product.user, email: "bob@gumroad.com", ip_address: ip,
                    purchase_state: "failed", stripe_status: "payment_intent.payment_failed", created_at: 1.day.ago)
    purchase2 = build_purchase(link: product, email: "bob@gumroad.com", ip_address: ip, created_at: Time.current)
    assert purchase2.valid?
  end

  test "not_double_charged settling allows a purchase from a different buyer email" do
    product = create_product
    ip = unique_ip
    create_purchase(link: product, seller: product.user, email: "bob@gumroad.com", ip_address: ip,
                    purchase_state: "in_progress", stripe_status: "processing", created_at: 1.day.ago)
    purchase2 = build_purchase(link: product, email: "alice@gumroad.com", ip_address: ip, created_at: Time.current)
    assert purchase2.valid?
  end

  test "not_double_charged settling allows a repeat purchase of a different variant" do
    ip = unique_ip
    product = create_product
    category = create_variant_category(link: product)
    variant_a = create_variant(variant_category: category)
    variant_b = create_variant(variant_category: category)
    settling = create_purchase(link: product, seller: product.user, email: "bob@gumroad.com", ip_address: ip,
                               purchase_state: "in_progress", stripe_status: "processing", created_at: 1.day.ago)
    settling.variant_attributes << variant_a
    purchase2 = build_purchase(link: product, email: "bob@gumroad.com", ip_address: ip, created_at: Time.current)
    purchase2.variant_attributes << variant_b
    assert purchase2.valid?
  end

  test "not_double_charged settling already blocks a repeat gift to the same giftee via the gift join in the parent check without any time window" do
    product = create_product
    ip = unique_ip
    gift = create_gift(giftee_email: "giftee@gumroad.com", link: product)
    create_purchase(link: product, seller: product.user, email: "sender@gumroad.com", ip_address: ip,
                    gift_given: gift, is_gift_sender_purchase: true,
                    purchase_state: "in_progress", stripe_status: "processing", created_at: 2.days.ago)
    second_gift = build_gift(giftee_email: "giftee@gumroad.com", link: product)
    purchase2 = build_purchase(link: product, email: "another-sender@gumroad.com", ip_address: ip,
                               gift_given: second_gift, is_gift_sender_purchase: true, created_at: Time.current)
    assert_not purchase2.valid?
    assert_equal ["You have already attempted to purchase this product. We will email you shortly if the purchase is successful."], purchase2.errors[:base]
  end

  test "not_double_charged settling already blocks a direct purchase by the giftee while a gift to them is in progress" do
    product = create_product
    ip = unique_ip
    gift = create_gift(giftee_email: "giftee@gumroad.com", link: product)
    create_purchase(link: product, seller: product.user, email: "sender@gumroad.com", ip_address: ip,
                    gift_given: gift, is_gift_sender_purchase: true,
                    purchase_state: "in_progress", stripe_status: "processing", created_at: 2.days.ago)
    purchase2 = build_purchase(link: product, email: "giftee@gumroad.com", ip_address: ip, created_at: Time.current)
    assert_not purchase2.valid?
  end

  # context "purchasing physical products"
  test "not_double_charged purchasing physical products prohibits double-charges within 10 seconds" do
    product = create_physical_product
    ip = unique_ip
    create_physical_purchase(link: product, seller: product.user, ip_address: ip, email: "bob@gumroad.com", variant_attributes: [product.skus.is_default_sku.first], created_at: 8.seconds.ago)
    purchase2 = build_physical_purchase(link: product, ip_address: ip, email: "bob@gumroad.com", variant_attributes: [product.skus.is_default_sku.first])
    assert_not purchase2.valid?
    assert_equal ["You have already paid for this product. It has been emailed to you."], purchase2.errors[:base]
  end

  test "not_double_charged purchasing physical products allows double-charges after 10 seconds" do
    product = create_physical_product
    ip = unique_ip
    create_physical_purchase(link: product, seller: product.user, ip_address: ip, email: "bob@gumroad.com", variant_attributes: [product.skus.is_default_sku.first], created_at: 11.seconds.ago)
    purchase2 = build_physical_purchase(link: product, ip_address: ip, email: "bob@gumroad.com", variant_attributes: [product.skus.is_default_sku.first])
    assert purchase2.valid?
  end

  # context "purchasing licensed products"
  test "not_double_charged purchasing licensed products prohibits double-charges within 10 seconds" do
    product = create_product(is_licensed: true)
    ip = unique_ip
    create_purchase(link: product, seller: product.user, ip_address: ip, email: "bob@gumroad.com", created_at: 8.seconds.ago)
    purchase2 = build_purchase(link: product, ip_address: ip, email: "bob@gumroad.com")
    assert_not purchase2.valid?
    assert_equal ["You have already paid for this product. It has been emailed to you."], purchase2.errors[:base]
  end

  test "not_double_charged purchasing licensed products allows double-charges after 10 seconds" do
    product = create_product(is_licensed: true)
    ip = unique_ip
    create_purchase(link: product, seller: product.user, ip_address: ip, email: "bob@gumroad.com", created_at: 11.seconds.ago)
    purchase2 = build_purchase(link: product, ip_address: ip, email: "bob@gumroad.com")
    assert purchase2.valid?
  end

  # context "when upgrading a subscription"
  test "not_double_charged when upgrading a subscription prohibits double-charges within 10 seconds" do
    ip = unique_ip
    purchase = create_membership_purchase(ip_address: ip, email: "bob@gumroad.com", created_at: 5.seconds.ago)
    purchase2 = build_membership_purchase_p3(ip_address: ip, email: "bob@gumroad.com", subscription: purchase.subscription, link: purchase.link, is_original_subscription_purchase: false, is_upgrade_purchase: true)
    assert_not purchase2.valid?
    assert_equal ["You have already paid for this product. It has been emailed to you."], purchase2.errors[:base]
  end

  test "not_double_charged when upgrading a subscription allows double-charges after 10 seconds" do
    ip = unique_ip
    purchase = create_membership_purchase(ip_address: ip, email: "bob@gumroad.com", created_at: 11.seconds.ago)
    purchase2 = build_membership_purchase_p3(ip_address: ip, email: "bob@gumroad.com", subscription: purchase.subscription, link: purchase.link, is_original_subscription_purchase: false, is_upgrade_purchase: true)
    assert purchase2.valid?
  end

  # ==========================================================================
  # describe "purchaser_email_or_email"
  # ==========================================================================

  test "purchaser_email_or_email provides email if no purchaser" do
    purchase = create_purchase(email: "bob@example.com", purchaser: nil)
    assert_equal "bob@example.com", purchase.purchaser_email_or_email
  end

  test "purchaser_email_or_email provides purchaser email if it exists" do
    buyer = create_user(email: "margaret@example.com")
    purchase = create_purchase(email: "email@email.email", purchaser: buyer)
    assert_equal "margaret@example.com", purchase.purchaser_email_or_email
  end

  test "purchaser_email_or_email provides email if purchase email blank" do
    buyer = create_user(email: "", provider: :twitter)
    purchase = create_purchase(purchaser: buyer)
    assert purchase.purchaser_email_or_email.present?
  end

  test "purchaser_email_or_email provides email if both are present" do
    buyer = create_user(email: "margaret@example.com")
    purchase = create_purchase(email: "bob@example.com", purchaser: buyer)
    assert_equal "margaret@example.com", purchase.purchaser_email_or_email
  end

  # ==========================================================================
  # describe "additional information passed to charge processor" (cassette-backed)
  # ==========================================================================

  test "additional information passed to charge processor reference is sent with the default if the statement description isnt customized" do
    link = create_product
    VCR.use_cassette("Purchase/additional_information_passed_to_charge_processor/reference/is_sent_with_the_default_if_the_statement_description_isn_t_customized") do
      chargeable = build_chargeable
      purchase = create_purchase_with_balance(link:, chargeable:)
      captured = capture_charge_processor_call(call_original: true) do
        purchase.process!
      end
      assert_equal purchase.external_id, captured.last[:args][4]
    end
  end

  test "additional information passed to charge processor soft descriptor with creator is sent with creator name" do
    user = create_user(name: "Gumbot")
    product = create_product(user:)
    VCR.use_cassette("Purchase/additional_information_passed_to_charge_processor/soft_descriptor_with_creator/is_sent_with_creator_name") do
      chargeable = build_chargeable
      purchase = create_purchase(chargeable:, purchase_state: "in_progress", link: product)
      captured = capture_charge_processor_call(call_original: true) do
        purchase.process!
      end
      call = captured.last
      assert_equal chargeable, call[:args][1]
      assert_equal user.name_or_username, call[:kwargs][:statement_description]
      assert_equal purchase.id, call[:kwargs][:transfer_group]
    end
  end

  test "additional information passed to charge processor mandate_expected is true when charging a recurring subscription purchase" do
    # The :recurring_membership_purchase factory seeds an original purchase on the
    # subscription in its after(:create); create_recurring_membership_purchase doesn't,
    # and price validation reads the subscription's original purchase — so seed it here.
    product = create_membership_product
    subscription = create_subscription(link: product)
    create_membership_purchase(link: product, subscription:)
    purchase = create_recurring_membership_purchase(link: product, subscription:, purchase_state: "in_progress")
    VCR.use_cassette("Purchase/additional_information_passed_to_charge_processor/mandate_expected/is_true_when_charging_a_recurring_subscription_purchase") do
      captured = capture_charge_processor_call(returns: stub(id: nil)) do
        purchase.send(:create_charge_intent, build_chargeable, off_session: true)
      end
      assert_equal true, captured.last[:kwargs][:mandate_expected]
    end
  end

  test "additional information passed to charge processor mandate_expected is true when charging a preorder release" do
    product = create_product(is_in_preorder_state: true)
    preorder_link = create_preorder_link(link: product)
    authorization_purchase = create_preorder_authorization_purchase(link: product)
    preorder = preorder_link.build_preorder(authorization_purchase)
    preorder.save!
    purchase = create_purchase(purchase_state: "in_progress", link: product, preorder:)
    VCR.use_cassette("Purchase/additional_information_passed_to_charge_processor/mandate_expected/is_true_when_charging_a_preorder_release") do
      captured = capture_charge_processor_call(returns: stub(id: nil)) do
        purchase.send(:create_charge_intent, build_chargeable, off_session: true)
      end
      assert_equal true, captured.last[:kwargs][:mandate_expected]
    end
  end

  test "additional information passed to charge processor mandate_expected is false when charging a first-time purchase" do
    purchase = create_purchase(purchase_state: "in_progress")
    VCR.use_cassette("Purchase/additional_information_passed_to_charge_processor/mandate_expected/is_false_when_charging_a_first-time_purchase") do
      captured = capture_charge_processor_call(returns: stub(id: nil)) do
        purchase.send(:create_charge_intent, build_chargeable, off_session: true)
      end
      assert_equal false, captured.last[:kwargs][:mandate_expected]
    end
  end

  # ==========================================================================
  # describe "total_transaction_amount_for_gumroad_cents" (cassette-backed)
  # ==========================================================================

  test "total_transaction_amount_for_gumroad_cents is the sum of the fee cents and tax that gumroad collected" do
    seller = create_user(name: "Seller")
    link = create_product(user: seller, price_cents: 4_00)
    VCR.use_cassette("Purchase/total_transaction_amount_for_gumroad_cents/is_the_sum_of_the_fee_cents_and_tax_that_gumroad_collected") do
      chargeable = build_chargeable
      purchase = create_purchase_with_balance(chargeable:, seller:, link:)
      purchase.stubs(:gumroad_tax_cents).returns(50)
      purchase.stubs(:total_transaction_cents).returns(4_50)
      assert_equal 182, purchase.total_transaction_amount_for_gumroad_cents # 132c fee (10% + 50c + 2.9% + 30c) + 50c gumroad tax
    end
  end

  test "total_transaction_amount_for_gumroad_cents use when charging is sent to the charge processor" do
    seller = create_user(name: "Seller")
    link = create_product(user: seller, price_cents: 4_00)
    VCR.use_cassette("Purchase/total_transaction_amount_for_gumroad_cents/use_when_charging/is_sent_to_the_charge_processor") do
      chargeable = build_chargeable
      purchase = create_purchase_with_balance(chargeable:, seller:, link:)
      purchase.stubs(:gumroad_tax_cents).returns(50)
      purchase.stubs(:total_transaction_cents).returns(4_50)
      captured = capture_charge_processor_call(call_original: true) do
        purchase.process!
      end
      call = captured.last
      assert_equal chargeable, call[:args][1]
      assert_equal purchase.total_transaction_cents, call[:args][2]
      assert_equal purchase.total_transaction_amount_for_gumroad_cents, call[:args][3]
    end
  end

  # ==========================================================================
  # describe "#formatted_total_price"
  # ==========================================================================

  test "#formatted_total_price returns the formatted price" do
    purchase = create_purchase(price_cents: 500)
    assert_equal "$5", purchase.formatted_total_price
  end

  test "#formatted_total_price converts to the purchase currency" do
    purchase = create_purchase(price_cents: 500, displayed_price_currency_type: Currency::JPY, link: create_product(price_cents: 100, price_currency_type: Currency::USD))
    purchase.stubs(:get_rate).returns(150)
    assert_equal "¥750", purchase.formatted_total_price
  end

  # ==========================================================================
  # describe "calculate_price_range_cents"
  # ==========================================================================

  test "calculate_price_range_cents handles euro-style entries" do
    usd_link = create_product
    p_usd = create_purchase(link: usd_link, seller: usd_link.user)
    p_usd.price_range = "999,99"
    assert_equal 99_999, p_usd.send(:calculate_price_range_cents)
    p_usd.price_range = "999.99"
    assert_equal 99_999, p_usd.send(:calculate_price_range_cents)
    p_usd.price_range = "1.999,99"
    assert_equal 199_999, p_usd.send(:calculate_price_range_cents)
    p_usd.price_range = "1,999.99"
    assert_equal 199_999, p_usd.send(:calculate_price_range_cents)
    p_usd.price_range = "1,999"
    assert_equal 199_900, p_usd.send(:calculate_price_range_cents)
  end

  test "calculate_price_range_cents does nothing for single unit currencies" do
    yen_link = create_product(price_currency_type: "jpy")
    p_yen = create_purchase(link: yen_link, seller: yen_link.user)
    p_yen.price_range = "9,99"
    assert_equal 999, p_yen.send(:calculate_price_range_cents)
  end

  # ==========================================================================
  # describe "#purchase_info"
  # ==========================================================================

  test "#purchase_info returns correct purchase info" do
    link, purchase = setup_purchase_info_context
    url_redirect = create_url_redirect
    purchase.stubs(:url_redirect).returns(url_redirect)
    url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3?AWSAccessKeyId=AKIAJU7Y4N2WOSYMBKBA&Expires=1375117394&"
    url += "Signature=NVzpNIuQlqCyGrx%2BiySqSXBhis4%3D&response-content-disposition=attachment"
    url_redirect.stubs(:redirect_or_s3_location).returns(url)

    assert_equal({ should_show_receipt: true,
                   was_paid: true,
                   show_view_content_button_on_product_page: true,
                   is_recurring_billing: false,
                   is_physical: false,
                   has_files: true,
                   is_gift_receiver_purchase: false,
                   gift_receiver_text: " bought this for you.",
                   gift_sender_text: "You bought this for .",
                   is_gift_sender_purchase: false,
                   content_url: url_redirect.download_page_url,
                   redirect_token: url_redirect.token,
                   price: 100,
                   product_id: link.external_id,
                   has_third_party_analytics: false,
                   id: 1,
                   created_at: purchase.created_at,
                   email: "hi@gumroad.com",
                   email_digest: purchase.email_digest,
                   full_name: nil,
                   is_following: false,
                   product_rating: 4,
                   review: ProductReviewPresenter.new(purchase.product_review).review_form_props,
                   view_content_button_text: view_content_button_text(link),
                   account_by_this_email_exists: false,
                   display_product_reviews: true,
                   currency_type: "usd",
                   non_formatted_price: 100,
                   non_formatted_seller_tax_amount: "0",
                   has_sales_tax_to_show: false,
                   was_tax_excluded_from_price: false,
                   sales_tax_amount: "$0",
                   sales_tax_label: nil,
                   quantity: 1,
                   show_quantity: false,
                   has_sales_tax_or_shipping_to_show: false,
                   has_shipping_to_show: false,
                   shipping_amount: "$0",
                   total_price_including_tax_and_shipping: "$1",
                   subscription_has_lapsed: false,
                   url_redirect_external_id: url_redirect.external_id,
                   domain: DOMAIN,
                   protocol: PROTOCOL,
                   native_type: Link::NATIVE_TYPE_DIGITAL,
                   enabled_integrations: { "circle" => false, "discord" => false, "zoom" => false, "google_calendar" => false } },
                 Purchase.purchase_info(url_redirect, link, purchase))
  end

  test "#purchase_info returns purchase info with account_by_this_email_exists set to true if purchaser_id is set for the purchase" do
    link, purchase = setup_purchase_info_context
    url_redirect = create_url_redirect
    purchase.purchaser = create_user(email: purchase.email)
    purchase.save!

    assert_equal true, Purchase.purchase_info(url_redirect, link, purchase)[:account_by_this_email_exists]
  end

  test "#purchase_info returns nil for content_url and content_token if url_redirect is not present" do
    link, purchase = setup_purchase_info_context
    link.stubs(:url_redirect).returns(nil)
    assert_nil Purchase.purchase_info(nil, link, purchase)[:content_url]
    assert_nil Purchase.purchase_info(nil, link, purchase)[:redirect_token]
  end

  test "#purchase_info shows test purchase notice if purchase is a test" do
    link, purchase = setup_purchase_info_context
    purchase.stubs(:is_test_purchase?).returns(true)
    assert_equal "This was a test purchase — you have not been charged (you are seeing this message because you are logged in as the creator).", Purchase.purchase_info(create_url_redirect, link, purchase)[:test_purchase_notice]
  end

  test "#purchase_info returns sales tax amount and indicates it has sales tax to show if exclusive and present" do
    link, purchase = setup_purchase_info_context
    zip_tax_rate = create_zip_tax_rate(country: "us", combined_rate: 0.2)
    purchase.tax_cents = 25
    purchase.price_cents = 125
    purchase.total_transaction_cents = 125
    purchase.displayed_price_cents = 100
    purchase.was_purchase_taxable = true
    purchase.was_tax_excluded_from_price = true
    purchase.zip_tax_rate = zip_tax_rate

    assert_equal true, Purchase.purchase_info(nil, link, purchase)[:has_sales_tax_to_show]
    assert_equal "$0.25", Purchase.purchase_info(nil, link, purchase)[:sales_tax_amount]
    assert_equal "Sales tax", Purchase.purchase_info(nil, link, purchase)[:sales_tax_label]
    assert_equal "$1.25", Purchase.purchase_info(nil, link, purchase)[:total_price_including_tax_and_shipping]
    assert_equal true, Purchase.purchase_info(nil, link, purchase)[:was_tax_excluded_from_price]
  end

  test "#purchase_info returns sales tax amount and indicates it has sales tax to show if inclusive and present" do
    link, purchase = setup_purchase_info_context
    zip_tax_rate = create_zip_tax_rate(country: "us", combined_rate: 0.2)
    purchase.tax_cents = 25
    purchase.price_cents = 100
    purchase.total_transaction_cents = 100
    purchase.displayed_price_cents = 100
    purchase.was_purchase_taxable = true
    purchase.was_tax_excluded_from_price = false
    purchase.zip_tax_rate = zip_tax_rate

    assert_equal true, Purchase.purchase_info(nil, link, purchase)[:has_sales_tax_to_show]
    assert_equal "$0.25", Purchase.purchase_info(nil, link, purchase)[:sales_tax_amount]
    assert_equal "Sales tax (included)", Purchase.purchase_info(nil, link, purchase)[:sales_tax_label]
    assert_equal "$1", Purchase.purchase_info(nil, link, purchase)[:total_price_including_tax_and_shipping]
    assert_equal false, Purchase.purchase_info(nil, link, purchase)[:was_tax_excluded_from_price]
  end

  test "#purchase_info returns quantity and show_quantity for physical product purchase" do
    link, purchase = setup_purchase_info_context
    link.update_attribute(:is_physical, true)
    purchase.update_attribute(:quantity, 5)

    assert_equal true, Purchase.purchase_info(nil, link, purchase)[:show_quantity]
    assert_equal 5, Purchase.purchase_info(nil, link, purchase)[:quantity]
  end

  test "#purchase_info returns shipping and has_shipping_to_show for physical product purchase with shipping" do
    link, purchase = setup_purchase_info_context
    link.update_attribute(:is_physical, true)
    purchase.update_attribute(:shipping_cents, 10_00)

    assert_equal true, Purchase.purchase_info(nil, link, purchase)[:has_shipping_to_show]
    assert_equal "$10", Purchase.purchase_info(nil, link, purchase)[:shipping_amount]
  end

  test "#purchase_info returns the tracking url for physical product purchase where order has been shipped with tracking" do
    link, purchase = setup_purchase_info_context
    link.update_attribute(:is_physical, true)
    shipment = create_shipment(purchase:, tracking_url: "https://tools.usps.com/go/TrackConfirmAction?qtc_tLabels1=1234567890")
    shipment.mark_shipped

    assert_equal true, Purchase.purchase_info(nil, link, purchase)[:shipped]
    assert_equal shipment.tracking_url, Purchase.purchase_info(nil, link, purchase)[:tracking_url]
  end

  test "#purchase_info returns membership-specific information for a purchase" do
    purchase = create_membership_purchase(link: create_membership_product)
    product = purchase.link
    purchase.subscription.update!(cancelled_at: 1.minute.ago)
    purchase.variant_attributes.first.update!(name: "Base tier")

    assert_equal true, Purchase.purchase_info(nil, product, purchase)[:subscription_has_lapsed]
    assert_equal "Base tier", Purchase.purchase_info(nil, product, purchase)[:membership][:tier_name]
    assert_nil Purchase.purchase_info(nil, product, purchase)[:membership][:tier_description]
    assert_equal routes.manage_subscription_url(purchase.subscription.external_id, host: "#{PROTOCOL}://#{DOMAIN}"), Purchase.purchase_info(nil, product, purchase)[:membership][:manage_url]
  end

  test "#purchase_info returns license_key if it exists" do
    link, purchase = setup_purchase_info_context
    link.is_licensed = true
    license = create_license(link:, purchase:)
    assert_equal license.serial, Purchase.purchase_info(nil, link, purchase)[:license_key]
  end

  test "#purchase_info returns should_show_receipt as true if purchase is a received gift" do
    link, _purchase = setup_purchase_info_context
    purchase = create_purchase(is_gift_receiver_purchase: true, purchase_state: "gift_receiver_purchase_successful")
    assert_equal true, Purchase.purchase_info(nil, link, purchase)[:should_show_receipt]
  end

  test "#purchase_info bundle purchase includes bundle products" do
    purchase = create_purchase(link: create_bundle)
    purchase.create_artifacts_and_send_receipt!

    assert_equal(
      [
        {
          id: purchase.product_purchases.first.link.external_id,
          content_url: purchase.product_purchases.first.url_redirect.download_page_url,
        },
        {
          id: purchase.product_purchases.second.link.external_id,
          content_url: purchase.product_purchases.second.url_redirect.download_page_url,
        }
      ],
      Purchase.purchase_info(nil, purchase.link, purchase)[:bundle_products]
    )
  end

  # ==========================================================================
  # describe "#buyer_presentment_price_cents"
  # ==========================================================================

  test "#buyer_presentment_price_cents returns the pre-tax presentment price for tax-exclusive purchases" do
    purchase = purchase_with_presentment(was_tax_excluded_from_price: true)
    assert_equal 11_25, purchase.buyer_presentment_price_cents
  end

  test "#buyer_presentment_price_cents includes seller tax in the buyer-facing price for tax-inclusive purchases" do
    purchase = purchase_with_presentment(was_tax_excluded_from_price: false)
    assert_equal 12_50, purchase.buyer_presentment_price_cents
    assert_equal "CAD$12.50", purchase.formatted_buyer_presentment_price
  end

  test "#buyer_presentment_price_cents returns the per-unit buyer-facing price for quantity purchases" do
    purchase = purchase_with_presentment(was_tax_excluded_from_price: false, quantity: 2)
    assert_equal 6_25, purchase.buyer_presentment_price_per_unit_cents
    assert_equal "CAD$6.25", purchase.formatted_buyer_presentment_price_per_unit
  end

  test "#buyer_presentment_price_cents includes the tip in the price line but not in the per-unit price" do
    purchase = purchase_with_presentment(was_tax_excluded_from_price: true,
                                         presentment_price_cents: 10_00,
                                         presentment_tip_cents: 1_25)
    assert_equal 11_25, purchase.buyer_presentment_price_cents
    assert_equal 10_00, purchase.buyer_presentment_price_per_unit_cents
  end

  # ==========================================================================
  # describe "#purchase_response"
  # ==========================================================================

  test "#purchase_response returns unique permalink even if product has a custom permalink" do
    link, purchase, url_redirect = setup_purchase_response_context
    Purchase.stubs(:purchase_info).returns(purchase_info: {})
    assert_equal "unique", Purchase.purchase_response(url_redirect, link, purchase)[:permalink]
  end

  test "#purchase_response returns purchase response with purchase info and payload_for_ping_notification merged" do
    link, purchase, url_redirect = setup_purchase_response_context
    Purchase.stubs(:purchase_info).returns(purchase_info: {})
    purchase_response = { purchase_info: {},
                          success: true,
                          remaining: link.remaining_for_sale_count,
                          permalink: "unique",
                          name: link.name,
                          variants: link.variant_list,
                          extra_purchase_notice: nil,
                          twitter_share_url: link.twitter_share_url,
                          twitter_share_text: link.social_share_text }
    ping_payload = purchase.payload_for_ping_notification(url_parameters: purchase.url_parameters,
                                                          resource_name: ResourceSubscription::SALE_RESOURCE_NAME)
    assert_equal purchase_response.reverse_merge(ping_payload), Purchase.purchase_response(url_redirect, link, purchase)
  end

  test "#purchase_response returns emailed preorder notice if link is in preorder state" do
    link, purchase, url_redirect = setup_purchase_response_context
    Purchase.stubs(:purchase_info).returns(purchase_info: {})
    preorder_link = create_preorder_link
    link.stubs(:is_in_preorder_state).returns(true)
    link.stubs(:preorder_link).returns(preorder_link)
    Purchase.stubs(:displayable_release_at_date_and_time).returns("")
    assert_equal "You'll get it on .", Purchase.purchase_response(url_redirect, link, purchase)[:extra_purchase_notice]
  end

  test "#purchase_response returns emailed physical preorder notice if link is physical and in preorder state" do
    link, purchase, url_redirect = setup_purchase_response_context
    Purchase.stubs(:purchase_info).returns(purchase_info: {})
    preorder_link = create_preorder_link
    link.stubs(:is_in_preorder_state).returns(true)
    link.stubs(:is_physical).returns(true)
    link.stubs(:preorder_link).returns(preorder_link)
    Purchase.stubs(:displayable_release_at_date_and_time).returns("")
    assert_equal "You'll be charged on , and shipment will occur soon after.", Purchase.purchase_response(url_redirect, link, purchase)[:extra_purchase_notice]
  end

  test "#purchase_response returns subscription notice if link is subscription" do
    link, purchase, url_redirect = setup_purchase_response_context
    Purchase.stubs(:purchase_info).returns(purchase_info: {})
    link.stubs(:is_recurring_billing).returns(true)
    assert_equal "You will receive an email when there's new content.", Purchase.purchase_response(url_redirect, link, purchase)[:extra_purchase_notice]
  end

  test "#purchase_response returns physical subscription notice if link is a physical subscription" do
    link, purchase, url_redirect = setup_purchase_response_context
    Purchase.stubs(:purchase_info).returns(purchase_info: {})
    link.stubs(:is_recurring_billing).returns(true)
    link.stubs(:is_physical).returns(true)
    assert_equal "You will also receive updates over email.", Purchase.purchase_response(url_redirect, link, purchase)[:extra_purchase_notice]
  end

  # ==========================================================================
  # describe "#notify_seller!"
  # ==========================================================================

  test "#notify_seller! purchase is a bundle product purchase doesnt notify the seller" do
    purchase = create_purchase(is_bundle_product_purchase: true)
    purchase.notify_seller!
    assert_equal 0, enqueued_mailer_count(ContactingCreatorMailer, :notify)
  end

  test "#notify_seller! purchase is a commission completion purchase doesnt notify the seller" do
    purchase = create_purchase(is_commission_completion_purchase: true)
    purchase.notify_seller!
    assert_equal 0, enqueued_mailer_count(ContactingCreatorMailer, :notify)
  end

  # ==========================================================================
  # describe "#create_artifacts_and_send_receipt!"
  # ==========================================================================

  test "#create_artifacts_and_send_receipt! purchase is a bundle purchase creates bundle product purchase artifacts" do
    seller = create_user(name: "Seller")
    purchaser = create_buyer_user
    bundle = create_product(user: seller, is_bundle: true)

    product = create_product(user: seller, name: "Product", custom_fields: [create_custom_field(name: "Key", seller:)])
    bundle_product = create_bundle_product(bundle:, product:)

    versioned_product = create_product_with_digital_versions(user: seller, name: "Versioned product")
    create_bundle_product(bundle:, product: versioned_product, variant: versioned_product.alive_variants.first, quantity: 3)

    purchase = create_purchase(link: bundle, purchaser:, zip_code: "12345", purchase_custom_fields: [build_purchase_custom_field(name: "Key", value: "Value", bundle_product:)])

    purchase.create_artifacts_and_send_receipt!

    purchase.reload
    assert_equal true, purchase.is_bundle_purchase
    assert_equal 2, purchase.product_purchases.count
    assert_empty purchase.purchase_custom_fields

    product_purchase2 = Purchase.last
    assert_equal versioned_product, product_purchase2.link
    assert_equal 3, product_purchase2.quantity
    assert_equal [versioned_product.alive_variants.first], product_purchase2.variant_attributes.to_a

    product_purchase1 = Purchase.second_to_last
    assert_equal product, product_purchase1.link
    assert_equal 1, product_purchase1.quantity
    assert_equal [], product_purchase1.variant_attributes.to_a
    sole_custom_field = product_purchase1.purchase_custom_fields.sole
    assert_equal "Key", sole_custom_field.name
    assert_equal "Value", sole_custom_field.value
    assert_nil sole_custom_field.bundle_product

    [product_purchase1, product_purchase2].each do |product_purchase|
      assert_equal 0, product_purchase.total_transaction_cents
      assert_equal 0, product_purchase.displayed_price_cents
      assert_equal 0, product_purchase.fee_cents
      assert_equal 0, product_purchase.price_cents
      assert_equal 0, product_purchase.gumroad_tax_cents
      assert_equal 0, product_purchase.shipping_cents

      assert_equal true, product_purchase.is_bundle_product_purchase
      assert_equal false, product_purchase.is_bundle_purchase

      assert_equal purchaser, product_purchase.purchaser
      # Every buyer/shipping/attribution field is copied verbatim from the parent bundle
      # purchase. Compare them as one slice: several are nil on a digital purchase, and a
      # per-field assert_equal with a nil expected trips Minitest's assert_nil deprecation.
      copied_fields = %w[email full_name street_address country state zip_code city
                         ip_address ip_state ip_country browser_guid referrer was_product_recommended]
      assert_equal purchase.attributes.slice(*copied_fields), product_purchase.attributes.slice(*copied_fields)
    end

    assert_equal [product_purchase1, product_purchase2], purchase.product_purchases.to_a
  end

  test "#create_artifacts_and_send_receipt! purchase is a bundle product purchase doesnt send the receipt" do
    purchase = create_purchase(is_bundle_product_purchase: true)
    purchase.notify_seller!
    assert_equal 0, enqueued_mailer_count(CustomerMailer, :receipt)
  end

  # ==========================================================================
  # describe "#mark_product_purchases_as_chargedback!"
  # ==========================================================================

  test "#mark_product_purchases_as_chargedback! marks all bundle purchases as charged back" do
    purchase = create_purchase(link: create_bundle)
    purchase.create_artifacts_and_send_receipt!

    assert_nil purchase.product_purchases.first.chargeback_date
    assert_nil purchase.product_purchases.second.chargeback_date
    purchase.mark_product_purchases_as_chargedback!
    assert_not_nil purchase.product_purchases.first.chargeback_date
    assert_not_nil purchase.product_purchases.second.chargeback_date
  end

  test "#mark_product_purchases_as_chargedback! keeps the original chargeback_date of an already-chargedback bundle purchase" do
    purchase = create_purchase(link: create_bundle)
    purchase.create_artifacts_and_send_receipt!

    original_chargeback_date = 3.days.ago
    purchase.product_purchases.first.update!(chargeback_date: original_chargeback_date)

    purchase.mark_product_purchases_as_chargedback!

    assert_in_delta original_chargeback_date, purchase.product_purchases.first.reload.chargeback_date, 1.second
    assert_not_nil purchase.product_purchases.second.reload.chargeback_date
  end

  # ==========================================================================
  # describe "#mark_product_purchases_as_chargeback_reversed!"
  # ==========================================================================

  test "#mark_product_purchases_as_chargeback_reversed! marks all bundle purchases as chargeback reversed" do
    purchase = create_purchase(link: create_bundle)
    purchase.create_artifacts_and_send_receipt!

    assert_equal false, purchase.product_purchases.first.chargeback_reversed
    assert_equal false, purchase.product_purchases.second.chargeback_reversed
    purchase.mark_product_purchases_as_chargeback_reversed!
    assert_equal true, purchase.product_purchases.first.chargeback_reversed
    assert_equal true, purchase.product_purchases.second.chargeback_reversed
  end

  # ==========================================================================
  # describe "#mark_product_purchases_as_refunded!"
  # ==========================================================================

  test "#mark_product_purchases_as_refunded! marks all bundle product purchases as fully refunded" do
    purchase = create_purchase(link: create_bundle)
    purchase.create_artifacts_and_send_receipt!

    assert purchase.product_purchases.pluck(:stripe_refunded).all?(&:nil?)
    purchase.mark_product_purchases_as_refunded!(is_partially_refunded: false)
    assert purchase.product_purchases.pluck(:stripe_refunded).all? { |v| v == true }
  end

  test "#mark_product_purchases_as_refunded! marks all bundle product purchases as partially refunded" do
    purchase = create_purchase(link: create_bundle)
    purchase.create_artifacts_and_send_receipt!

    assert purchase.product_purchases.pluck(:stripe_partially_refunded).all? { |v| v == false }
    purchase.mark_product_purchases_as_refunded!(is_partially_refunded: true)
    assert purchase.product_purchases.pluck(:stripe_partially_refunded).all? { |v| v == true }
  end

  # ==========================================================================
  # describe "#has_content?"
  # ==========================================================================

  test "#has_content? when product has files returns true if webhook did not fail pdf stamp is disabled and url redirect is present" do
    product = create_product_with_files
    purchase = create_purchase(link: product)
    create_url_redirect(purchase:, link: product)
    purchase.stubs(:webhook_failed).returns(false)

    assert_equal true, purchase.has_content?
  end

  test "#has_content? when product has files returns false if webhook has failed" do
    product = create_product_with_files
    purchase = create_purchase(link: product)
    create_url_redirect(purchase:, link: product)
    purchase.stubs(:webhook_failed).returns(true)

    assert_equal false, purchase.has_content?
  end

  test "#has_content? when product has files returns false if product has stampable files but the stamping hasnt finished" do
    product = create_product_with_files
    purchase = create_purchase(link: product)
    create_url_redirect(purchase:, link: product)
    purchase.stubs(:webhook_failed).returns(false)
    product.product_files << create_readable_document(pdf_stamp_enabled: true)

    assert_equal false, purchase.has_content?
  end

  test "#has_content? when product has files returns true if product has stampable files and the stamping has finished" do
    product = create_product_with_files
    purchase = create_purchase(link: product)
    create_url_redirect(purchase:, link: product)
    purchase.stubs(:webhook_failed).returns(false)
    product.product_files << create_readable_document(pdf_stamp_enabled: true)

    purchase.url_redirect.stubs(:is_done_pdf_stamping).returns(true)
    assert_equal true, purchase.has_content?
  end

  test "#has_content? when product has files returns false if url redirect is nil" do
    product = create_product_with_files
    purchase = create_purchase(link: product)
    create_url_redirect(purchase:, link: product)
    purchase.stubs(:webhook_failed).returns(false)
    purchase.stubs(:url_redirect).returns(nil)
    assert_equal false, purchase.has_content?
  end

  test "#has_content? when product does not have files returns true" do
    product = create_product
    purchase = create_purchase(link: product)
    create_url_redirect(purchase:, link: product)
    purchase.stubs(:webhook_failed).returns(false)

    assert_equal true, purchase.has_content?
  end

  # ==========================================================================
  # describe "#successful_and_valid?"
  # ==========================================================================

  test "#successful_and_valid? returns true if it is successful not charged back not refunded and not additional contribution" do
    purchase = create_purchase(purchase_state: "successful", chargeback_date: nil, stripe_refunded: false)
    assert_equal true, purchase.successful_and_valid?
  end

  test "#successful_and_valid? returns false if it is not successful" do
    purchase = create_purchase(purchase_state: "failed", chargeback_date: nil, stripe_refunded: false)
    assert_equal false, purchase.successful_and_valid?
  end

  test "#successful_and_valid? returns false if it has been charged back" do
    purchase = create_purchase(purchase_state: "successful", chargeback_date: DateTime.current, stripe_refunded: false)
    assert_equal false, purchase.successful_and_valid?
  end

  test "#successful_and_valid? returns false if it has been refunded" do
    purchase = create_purchase(purchase_state: "successful", chargeback_date: nil, stripe_refunded: true)
    assert_equal false, purchase.successful_and_valid?
  end

  test "#successful_and_valid? returns false if it is a test purchase" do
    link = create_product
    purchase = create_purchase(link:, purchaser: link.user, purchase_state: "test_successful", chargeback_date: nil, stripe_refunded: false)
    assert_equal false, purchase.successful_and_valid?
  end

  test "#successful_and_valid? subscription purchase returns true if it has not been cancelled nor failed" do
    subscription_link = create_subscription_product
    subscription = create_subscription
    create_purchase(link: subscription_link, subscription:, purchase_state: "successful",
                    chargeback_date: nil, stripe_refunded: false, is_original_subscription_purchase: true)
    subscription_purchase = create_purchase(link: subscription_link, subscription:, purchase_state: "successful",
                                            chargeback_date: nil, stripe_refunded: false)
    assert_equal true, subscription_purchase.successful_and_valid?
  end

  test "#successful_and_valid? subscription purchase returns true if the subscription has been upgraded" do
    subscription_link = create_subscription_product
    subscription = create_subscription
    original_purchase = create_purchase(link: subscription_link, subscription:, purchase_state: "successful",
                                        chargeback_date: nil, stripe_refunded: false, is_original_subscription_purchase: true)
    original_purchase.update!(is_archived_original_subscription_purchase: true)
    new_original_purchase = create_purchase(link: subscription_link, subscription:, purchase_state: "not_charged",
                                            chargeback_date: nil, stripe_refunded: false, is_original_subscription_purchase: true)

    assert_equal true, new_original_purchase.successful_and_valid?
  end

  test "#successful_and_valid? subscription purchase returns false if it has been cancelled" do
    subscription_link = create_subscription_product
    subscription = create_subscription
    create_purchase(link: subscription_link, subscription:, purchase_state: "successful",
                    chargeback_date: nil, stripe_refunded: false, is_original_subscription_purchase: true)
    subscription_purchase = create_purchase(link: subscription_link, subscription:, purchase_state: "successful",
                                            chargeback_date: nil, stripe_refunded: false)
    subscription.stubs(:cancelled_at).returns(DateTime.current)
    assert_equal false, subscription_purchase.successful_and_valid?
  end

  test "#successful_and_valid? subscription purchase returns false if it has been failed" do
    subscription_link = create_subscription_product
    subscription = create_subscription
    create_purchase(link: subscription_link, subscription:, purchase_state: "successful",
                    chargeback_date: nil, stripe_refunded: false, is_original_subscription_purchase: true)
    subscription_purchase = create_purchase(link: subscription_link, subscription:, purchase_state: "successful",
                                            chargeback_date: nil, stripe_refunded: false)
    subscription.stubs(:failed_at).returns(DateTime.current)
    assert_equal false, subscription_purchase.successful_and_valid?
  end

  # ==========================================================================
  # describe "#successful_and_not_reversed?"
  # ==========================================================================

  test "#successful_and_not_reversed? when include_gift is false returns true for a successful purchase" do
    ["preorder_authorization_successful", "successful", "not_charged"].each do |successful_state|
      purchase = build_purchase(purchase_state: successful_state)
      assert_equal true, purchase.successful_and_not_reversed?
    end
  end

  test "#successful_and_not_reversed? when include_gift is false returns false for a successful chargedback purchase" do
    purchase = build_purchase(purchase_state: "successful", chargeback_date: 1.day.ago)
    assert_equal false, purchase.successful_and_not_reversed?
  end

  test "#successful_and_not_reversed? when include_gift is false returns false for a successful refunded purchase" do
    purchase = build_purchase(purchase_state: "successful", stripe_refunded: true)
    assert_equal false, purchase.successful_and_not_reversed?
  end

  test "#successful_and_not_reversed? when include_gift is false returns false for a received gift purchase" do
    purchase = build_purchase(is_gift_receiver_purchase: true, purchase_state: "gift_receiver_purchase_successful")
    assert_equal false, purchase.successful_and_not_reversed?
  end

  test "#successful_and_not_reversed? when include_gift is true returns true for a successful purchase" do
    ["preorder_authorization_successful", "successful", "not_charged"].each do |successful_state|
      purchase = build_purchase(purchase_state: successful_state)
      assert_equal true, purchase.successful_and_not_reversed?(include_gift: true)
    end
  end

  test "#successful_and_not_reversed? when include_gift is true returns false for a successful chargedback purchase" do
    purchase = build_purchase(purchase_state: "successful", chargeback_date: 1.day.ago)
    assert_equal false, purchase.successful_and_not_reversed?(include_gift: true)
  end

  test "#successful_and_not_reversed? when include_gift is true returns false for a successful refunded purchase" do
    purchase = build_purchase(purchase_state: "successful", stripe_refunded: true)
    assert_equal false, purchase.successful_and_not_reversed?(include_gift: true)
  end

  test "#successful_and_not_reversed? when include_gift is true returns true for a received gift purchase" do
    purchase = build_purchase(is_gift_receiver_purchase: true, purchase_state: "gift_receiver_purchase_successful")
    assert_equal true, purchase.successful_and_not_reversed?(include_gift: true)
  end

  # ==========================================================================
  # describe "when the user specifies their own zip (e.g. via shipping)"
  # ==========================================================================

  test "when the user specifies their own zip correctly parses the zip from different formats" do
    assert_equal "94301", parse_zip("94301")
    assert_equal "02912", parse_zip("02912-9001")
    assert_equal "90210", parse_zip(" 90210")
    assert_equal "90210", parse_zip("90210 ")
    assert_equal "02912", parse_zip("029129001")
    assert_nil parse_zip("20394023492034")
    assert_nil parse_zip("j#*(#/asdfie3 sdf3")
    assert_nil parse_zip("string90210morestring")
    assert_nil parse_zip("94301sdflkj")
    assert_equal "10016", parse_zip("10016 7808")
  end

  # ==========================================================================
  # describe "when a product's sales number changes"
  # ==========================================================================

  test "when a products sales number changes schedules a sidekiq job to invalidate the products cache in 1 minute" do
    product = create_product
    purchase = create_purchase(link: product, purchase_state: "in_progress")

    purchase.mark_successful!
    assert_equal 1, InvalidateProductCacheWorker.jobs.size
    job = InvalidateProductCacheWorker.jobs.last
    assert_equal [purchase.link.id], job["args"]
    assert_in_delta 1.minute.from_now.to_f, job["at"], 1
  end

  # ==========================================================================
  # describe "successful purchase"
  # ==========================================================================

  test "successful purchase schedules a sidekiq job to invalidate the products cache on inventory change in 1 minute" do
    product, _sku, purchase = successful_purchase_context

    purchase.variant_attributes = []
    purchase.save!
    product.update_column(:max_purchase_count, 10)

    purchase.update_balance_and_mark_successful!
    assert_equal 1, InvalidateProductCacheWorker.jobs.size
    job = InvalidateProductCacheWorker.jobs.last
    assert_equal [purchase.link.id], job["args"]
    assert_in_delta 1.minute.from_now.to_f, job["at"], 1
  end

  test "successful purchase sets updated_at on the sku" do
    product, _sku, _purchase = successful_purchase_context

    category1 = create_variant_category(title: "Size", link: product)
    create_variant(variant_category: category1, name: "Small")
    category2 = create_variant_category(title: "Color", link: product)
    create_variant(variant_category: category2, name: "Red")
    travel_to(1.minute.ago) { Product::SkusUpdaterService.new(product:).perform }
    product.update_column(:max_purchase_count, 10)

    VCR.use_cassette("Purchase/successful_purchase/sets_updated_at_on_the_sku") do
      chargeable = build_chargeable
      purchase = build_physical_purchase(link: product, chargeable:, perceived_price_cents: 100, save_card: false, price_range: 1, purchase_state: "in_progress")
      purchase.variant_attributes << Sku.last

      travel_to(Time.current) do
        purchase.mark_successful
        assert_equal Time.current.to_i, product.skus.last.updated_at.to_i
      end
    end
  end

  # ==========================================================================
  # describe "probation"
  # ==========================================================================

  test "probation does not put the seller on probation for expensive sales" do
    product = create_physical_product(user: create_compliant_user)
    purchase = build_physical_purchase(link: product, variant_attributes: [product.skus.last], seller: product.user, purchase_state: "in_progress")
    purchase.update!(price_cents: 1000_00)

    purchase.mark_successful!

    assert_equal false, purchase.seller.on_probation?
  end

  # ==========================================================================
  # describe "licenses"
  # ==========================================================================

  test "licenses does not create a license for the gifter" do
    gifter_purchase, giftee_purchase, _product = licenses_setup
    giftee_purchase.mark_gift_receiver_purchase_successful
    assert_nil gifter_purchase.reload.license
    assert_not_nil giftee_purchase.reload.license
  end

  test "licenses has the same license key for all subsequent purchases of a subscription as the original purchase" do
    _gifter_purchase, _giftee_purchase, product = licenses_setup
    user = create_user
    subscription = create_subscription(user:, link: product)
    original_subscription_purchase = create_purchase(link: product, email: user.email, is_original_subscription_purchase: true,
                                                     subscription:, purchase_state: "in_progress")

    original_subscription_purchase.mark_successful!
    assert_not_nil original_subscription_purchase.license.serial

    recurring_purchase = create_purchase(link: product, email: user.email, is_original_subscription_purchase: false,
                                         subscription:, purchase_state: "in_progress")
    recurring_purchase.mark_successful!
    assert_equal original_subscription_purchase.license.serial, recurring_purchase.license.serial
  end

  test "licenses #license_json returns the license information" do
    product = create_product(is_licensed: true)
    purchase = create_purchase(link: product)
    license = create_license(link: product, purchase:)

    assert_equal({
                   license_key: license.serial,
                   license_id: license.external_id,
                   license_disabled: false,
                   license_uses: 0,
                   is_multiseat_license: false,
                 }, purchase.send(:license_json))
  end

  test "licenses #license_json when multiseat is disabled returns is_multiseat_license as false" do
    product = create_product(is_licensed: true)
    purchase = create_purchase(link: product)
    license = create_license(link: product, purchase:)

    assert_equal({
                   license_key: license.serial,
                   license_id: license.external_id,
                   license_disabled: false,
                   license_uses: 0,
                   is_multiseat_license: false,
                 }, purchase.send(:license_json))
  end

  test "licenses #license_json when multiseat is enabled returns is_multiseat_license as true" do
    product = create_product(is_licensed: true)
    product.update(is_multiseat_license: true)
    purchase = create_purchase(link: product)
    license = create_license(link: product, purchase:)

    assert_equal({
                   license_key: license.serial,
                   license_id: license.external_id,
                   license_disabled: false,
                   license_uses: 0,
                   is_multiseat_license: true,
                 }, purchase.send(:license_json))
  end

  test "licenses assign_is_multiseat_license copies the products multiseat flag onto the purchase" do
    product = create_product(is_licensed: true)
    product.update(is_multiseat_license: true)
    purchase = create_purchase(link: product)

    assert_equal true, purchase.is_multiseat_license
  end

  test "licenses assign_is_multiseat_license does not mark a call purchase multiseat even when the product flag is set" do
    call = create_call_product_available_for_a_year(price_cents: 1000, is_licensed: true)
    call.update_attribute(:is_multiseat_license, true)
    purchase = create_call_purchase(link: call)

    assert_equal false, purchase.is_multiseat_license
  end

  # ==========================================================================
  # describe "variant_names_hash" (cassette-backed)
  # ==========================================================================

  test "variant_names_hash returns the selected SKU regardless of skus_enabled" do
    product, _variant1, _variant2 = variant_names_hash_context
    VCR.use_cassette("Purchase/variant_names_hash/returns_the_selected_SKU_regardless_of_skus_enabled") do
      chargeable = build_chargeable
      purchase = build_purchase(link: product, chargeable:, perceived_price_cents: 100, save_card: false,
                                ip_address: IP_ADDRESS, price_range: 1)
      purchase.variant_attributes << Sku.last

      purchase.process!
      purchase.link.update!(skus_enabled: false)
      assert_equal({ "Size - Color" => "Small - Red" }, purchase.variant_names_hash)
    end
  end

  test "variant_names_hash returns the selected variants regardless of skus_enabled" do
    product, variant1, variant2 = variant_names_hash_context
    VCR.use_cassette("Purchase/variant_names_hash/returns_the_selected_variants_regardless_of_skus_enabled") do
      chargeable = build_chargeable
      purchase = build_purchase(link: product, chargeable:, perceived_price_cents: 100, save_card: false,
                                ip_address: IP_ADDRESS, price_range: 1)
      purchase.variant_attributes << Sku.last

      purchase.variant_attributes.clear
      purchase.variant_attributes << [variant1, variant2]
      assert_equal({ "Size" => "Small", "Color" => "Red" }, purchase.variant_names_hash)
    end
  end

  # ==========================================================================
  # describe "referrer"
  # ==========================================================================

  test "referrer truncates the referrer and then save it" do
    purchase = create_purchase(referrer: "a" * 1000)
    assert_equal "a" * 191, purchase.referrer
  end

  # ==========================================================================
  # describe "#schedule_subscription_jobs"
  # ==========================================================================

  test "#schedule_subscription_jobs schedules the job to end the subscription if the set number of charges have completed" do
    product = create_membership_product(subscription_duration: BasePrice::Recurrence::MONTHLY)
    subscription = create_subscription(link: product, charge_occurrence_count: 2)
    create_purchase(link: product, is_original_subscription_purchase: true, subscription:)

    purchase = create_purchase_in_progress(link: product, subscription:)
    purchase.process!

    travel_to(Time.current)

    purchase.mark_successful!
    assert_sidekiq_enqueued(EndSubscriptionWorker, args: [subscription.id], at: 1.month.from_now)
  end

  # ==========================================================================
  # describe "rental expiration reminder emails"
  # ==========================================================================

  test "rental expiration reminder emails has scheduled all 3 reminder email jobs" do
    travel_to(Time.zone.parse("2015-03-12T00:00:00Z"))
    product = create_product_with_video_file(purchase_type: :buy_and_rent, price_cents: 500, rental_price_cents: 200, name: "rental test")
    purchase = create_purchase_with_balance(link: product, is_rental: true)

    assert_sidekiq_enqueued(SendRentalExpiresSoonEmailWorker, args: [purchase.id, 1.day.to_i], at: 29.days.from_now)
    assert_sidekiq_enqueued(SendRentalExpiresSoonEmailWorker, args: [purchase.id, 3.days.to_i], at: 27.days.from_now)
    assert_sidekiq_enqueued(SendRentalExpiresSoonEmailWorker, args: [purchase.id, 7.days.to_i], at: 23.days.from_now)
  end

  # =========================== from part 4 ===========================
  test "shipping charges standalone rate applied when shipped to a region that has a shipping rate configured - qty of 1" do
    VCR.use_cassette("Purchase/shipping_charges/standalone_rate_applied_when_shipped_to_a_region_that_has_a_shipping_rate_configured_-_qty_of_1") do
      setup_shipping_purchase
      @purchase.country = "United States"
      @purchase.zip_code = 94_107
      @purchase.state = "CA"
      @purchase.quantity = 1
      @purchase.save!

      with_expected_charge_amount(110_00) { @purchase.process! }

      assert_equal 110_00, @purchase.price_cents
      assert_equal 10_00, @purchase.shipping_cents
      assert_equal 0, @purchase.tax_cents
      assert_equal 14_99, @purchase.fee_cents
    end
  end

  test "shipping charges combined rate applied when shipped to a region that has a shipping rate configured - qty of 5" do
    VCR.use_cassette("Purchase/shipping_charges/combined_rate_applied_when_shipped_to_a_region_that_has_a_shipping_rate_configured_-_qty_of_5") do
      setup_shipping_purchase
      @purchase.country = "United States"
      @purchase.zip_code = 94_107
      @purchase.state = "CA"
      @purchase.quantity = 5
      @purchase.save!

      with_expected_charge_amount(530_00) { @purchase.process! }

      assert_equal 530_00, @purchase.price_cents
      assert_equal 30_00, @purchase.shipping_cents
      assert_equal 0, @purchase.tax_cents
      assert_equal 69_17, @purchase.fee_cents
    end
  end

  test "shipping charges virtual countries standalone rate applied when shipped to a region that has a shipping rate configured - qty of 1" do
    VCR.use_cassette("Purchase/shipping_charges/virtual_countries/standalone_rate_applied_when_shipped_to_a_region_that_has_a_shipping_rate_configured_-_qty_of_1") do
      setup_shipping_purchase
      @purchase.link.shipping_destinations << ShippingDestination.new(country_code: "EUROPE", one_item_rate_cents: 7_00, multiple_items_rate_cents: 10_00, is_virtual_country: true)
      @purchase.country = "France"
      @purchase.zip_code = 75_001
      @purchase.state = "Ile-de-France"
      @purchase.quantity = 1
      @purchase.save!

      create_zip_tax_rate(zip_code: 75_001, state: "Ile-de-France", country: Compliance::Countries::FRA.alpha2, combined_rate: 0.1)

      with_expected_charge_amount(107_00) { @purchase.process! }

      assert_equal 107_00, @purchase.price_cents
      assert_equal 7_00, @purchase.shipping_cents
      assert_equal 0, @purchase.tax_cents
      assert_equal 14_60, @purchase.fee_cents # 1070c (10%) + 50c + 310c (2.9% cc fee) + 30c
    end
  end

  test "shipping charges virtual countries combined rate applied when shipped to a region that has a shipping rate configured - qty of 5" do
    VCR.use_cassette("Purchase/shipping_charges/virtual_countries/combined_rate_applied_when_shipped_to_a_region_that_has_a_shipping_rate_configured_-_qty_of_5") do
      setup_shipping_purchase
      @purchase.link.shipping_destinations << ShippingDestination.new(country_code: "EUROPE", one_item_rate_cents: 7_00, multiple_items_rate_cents: 10_00, is_virtual_country: true)
      @purchase.country = "France"
      @purchase.zip_code = 75_001
      @purchase.state = "Ile-de-France"
      @purchase.quantity = 5
      @purchase.save!

      create_zip_tax_rate(zip_code: 75_001, state: "Ile-de-France", country: Compliance::Countries::FRA.alpha2, combined_rate: 0.1)

      with_expected_charge_amount(547_00) { @purchase.process! }

      assert_equal 547_00, @purchase.price_cents
      assert_equal 47_00, @purchase.shipping_cents
      assert_equal 0, @purchase.tax_cents
      assert_equal 71_36, @purchase.fee_cents # 54_70c (10%) + 50c + 1586c (2.9% cc fee) + 30c
    end
  end

  test "shipping charges validate shipping does not allow shipping to a region where there is no shipping rate configured" do
    VCR.use_cassette("Purchase/shipping_charges/validate_shipping/does_not_allow_shipping_to_a_region_where_there_is_no_shipping_rate_configured") do
      setup_shipping_purchase # outer before runs for the nested example too (tokenizes a chargeable)
      user = create_user
      phys_link = create_product(price_cents: 100_00, user:, is_physical: true, require_shipping: true)
      bad_purchase = create_physical_purchase(price_cents: 100_00, link: phys_link, chargeable: build_chargeable, country: "Germany")

      assert bad_purchase.errors[:base].present?
      assert_equal PurchaseErrorCode::NO_SHIPPING_COUNTRY_CONFIGURED, bad_purchase.error_code
    end
  end

  test "shipping charges validate shipping does not allow shipping to a region that is not compliant" do
    VCR.use_cassette("Purchase/shipping_charges/validate_shipping/does_not_allow_shipping_to_a_region_that_is_not_compliant") do
      setup_shipping_purchase # outer before runs for the nested example too (tokenizes a chargeable)
      user = create_user
      phys_link = create_product(price_cents: 100_00, user:, is_physical: true, require_shipping: true)
      bad_purchase = create_physical_purchase(price_cents: 100_00, link: phys_link, chargeable: build_chargeable, country: "Iran")

      assert bad_purchase.errors[:base].present?
      assert_equal PurchaseErrorCode::BLOCKED_SHIPPING_COUNTRY, bad_purchase.error_code
    end
  end

  test "shipping charges allows to ship to any destinate if ELSEWHERE is a configured shipping region" do
    VCR.use_cassette("Purchase/shipping_charges/allows_to_ship_to_any_destinate_if_ELSEWHERE_is_a_configured_shipping_region") do
      setup_shipping_purchase
      @purchase.country = "Germany"
      @purchase.link.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 10_00, multiple_items_rate_cents: 5_00)
      @purchase.quantity = 1
      @purchase.save!

      with_expected_charge_amount(110_00) { @purchase.process! }

      assert_equal 110_00, @purchase.price_cents
      assert_equal 10_00, @purchase.shipping_cents
      assert_equal 14_99, @purchase.fee_cents # 11_10c (10%) + 50c + 319c (2.9% cc fee) + 30c
    end
  end

  test "shipping charges converts the shipping charges to USD before charging" do
    VCR.use_cassette("Purchase/shipping_charges/converts_the_shipping_charges_to_USD_before_charging") do
      setup_shipping_purchase
      @purchase.country = "Germany"

      @purchase.link.price_currency_type = "gbp"
      @purchase.link.price_cents = 10000
      @purchase.link.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 10_00, multiple_items_rate_cents: 5_00)
      @purchase.link.save!

      @purchase.quantity = 1
      @purchase.save!

      expected_usd = @purchase.get_usd_cents("gbp", 110_00)
      with_expected_charge_amount(expected_usd) { @purchase.process! }

      assert_equal expected_usd, @purchase.price_cents
      assert_equal @purchase.get_usd_cents("gbp", 10_00), @purchase.shipping_cents
      assert_equal (@purchase.get_usd_cents("gbp", 110_00) * 0.129 + 50 + 30).truncate, @purchase.fee_cents
    end
  end

  test "shipping charges returns shipping added to price_cents if the purchase is a test purchase" do
    VCR.use_cassette("Purchase/shipping_charges/returns_shipping_added_to_price_cents_if_the_purchase_is_a_test_purchase") do
      setup_shipping_purchase
      @purchase.country = "Germany"
      @purchase.link.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 10_00, multiple_items_rate_cents: 5_00)
      @purchase.link.save!

      @purchase.purchaser = @purchase.link.user
      @purchase.quantity = 1
      @purchase.save!

      ChargeProcessor.expects(:charge!).never

      @purchase.process!

      @purchase.reload
      assert_equal 10_00, @purchase.shipping_cents
      assert_equal 110_00, @purchase.price_cents
      assert_equal 110_00, @purchase.total_transaction_cents
    end
  end

  # ---- validate quantity ----

  test "validate quantity renders purchases valid if the quantity is 1 or more" do
    product = create_product(price_cents: 100_00)
    purchase = create_purchase(price_cents: 100_00, link: product, quantity: 1)

    assert_not purchase.errors[:base].present?
    assert_nil purchase.error_code
  end

  test "validate quantity renders purchases invalid if the quantity is 0 or less" do
    product = create_product(price_cents: 100_00)
    purchase = create_purchase(price_cents: 0, link: product, quantity: 0)
    purchase1 = create_purchase(price_cents: 0, link: product, quantity: -1)

    assert purchase.errors[:base].present?
    assert_equal PurchaseErrorCode::INVALID_QUANTITY, purchase.error_code
    assert purchase1.errors[:base].present?
    assert_equal PurchaseErrorCode::INVALID_QUANTITY, purchase1.error_code
  end

  # ---- validate is_free_trial_purchase ----

  test "validate is_free_trial_purchase when product has free trial enabled requires is_free_trial_purchase to be set for initial purchase of product" do
    product = free_trial_product
    purchase = build_membership_purchase_p4(link: product, is_free_trial_purchase: true)
    assert purchase.valid?

    purchase.is_free_trial_purchase = false
    assert_not purchase.valid?
    assert_equal ["purchase should be marked as a free trial purchase"], purchase.errors[:base]
  end

  test "validate is_free_trial_purchase when product has free trial enabled does not require is_free_trial_purchase to be set when changing plan" do
    product = free_trial_product
    purchase = build_membership_purchase_p4(link: product, is_updated_original_subscription_purchase: true)
    assert purchase.valid?
  end

  test "validate is_free_trial_purchase when product has free trial enabled when the user has already subscribed allows re-purchasing if the existing subscriptions have paid charges" do
    product = free_trial_product
    email = "subscriber@example.com"
    existing_subscription = create_free_trial_membership_purchase(link: product, email:).subscription

    create_purchase(subscription: existing_subscription, link: product, email:, purchase_state: "successful")

    purchase = build_free_trial_membership_purchase(link: product, email:)
    assert purchase.valid?
  end

  test "validate is_free_trial_purchase when product has free trial enabled when the user has already subscribed does not allow re-purchasing if the existing subscriptions do not have paid charges" do
    product = free_trial_product
    email = "subscriber@example.com"
    existing_subscription = create_free_trial_membership_purchase(link: product, email:).subscription

    create_purchase(subscription: existing_subscription, link: product, email:, purchase_state: "successful", stripe_refunded: true)
    create_purchase(subscription: existing_subscription, link: product, email:, purchase_state: "successful", chargeback_date: 1.day.ago)
    purchase = build_free_trial_membership_purchase(link: product, email:)

    assert_not purchase.valid?
    assert_equal ["You've already purchased this product and are ineligible for a free trial. Please visit the Manage Membership page to re-start or make changes to your subscription."], purchase.errors[:base]
  end

  test "validate is_free_trial_purchase when product has free trial enabled recurring charges does not allow is_free_trial_purchase to be set for recurring charges" do
    product = free_trial_product
    original_purchase = create_membership_purchase(link: product, is_free_trial_purchase: true)
    purchase = build_purchase(subscription: original_purchase.subscription, link: product, is_free_trial_purchase: true)
    assert_not purchase.valid?
    assert_equal ["recurring charges should not be marked as free trial purchases"], purchase.errors[:base]
  end

  test "validate is_free_trial_purchase when product has free trial enabled recurring charges does not error if is_free_trial_purchase is not set" do
    product = free_trial_product
    original_purchase = create_membership_purchase(link: product, is_free_trial_purchase: true)
    purchase = build_purchase(subscription: original_purchase.subscription, link: product)
    assert purchase.valid?
  end

  test "validate is_free_trial_purchase when product does not have free trial enabled does not allow is_free_trial_purchase to be set" do
    purchase = build_membership_purchase_p4
    assert purchase.valid?

    purchase.is_free_trial_purchase = true
    assert_not purchase.valid?
    assert_equal ["free trial must be enabled on the product"], purchase.errors[:base]
  end

  test "validate is_free_trial_purchase when product does not have free trial enabled allows is_free_trial_purchase to be set for a pre-existing purchase" do
    purchase = create_membership_purchase
    purchase.is_free_trial_purchase = true

    assert purchase.valid?
  end

  test "validate is_free_trial_purchase when product does not have free trial enabled allows is_free_trial_purchase to be set when changing a subscription plan" do
    purchase = create_membership_purchase
    purchase.is_free_trial_purchase = true
    purchase.is_updated_original_subscription_purchase = true

    assert purchase.valid?
  end

  # ---- purchase sales tax info ----

  test "purchase sales tax info creates a purchase sales tax info entry if it does not have one" do
    VCR.use_cassette("Purchase/purchase_sales_tax_info/creates_a_purchase_sales_tax_info_entry_if_it_does_not_have_one") do
      purchase = create_purchase(price_cents: 100_00, chargeable: build_chargeable)
      purchase.sales_tax_country_code_election = Compliance::Countries::DEU.alpha2
      purchase.country = Compliance::Countries::USA.common_name
      purchase.zip_code = "94117"
      purchase.ip_address = "2.47.255.255"

      assert_nil purchase.purchase_sales_tax_info

      purchase.process!
      purchase.reload

      actual_purchase_sales_tax_info = Purchase.last.purchase_sales_tax_info
      assert_not_nil actual_purchase_sales_tax_info
      assert_equal Compliance::Countries::DEU.alpha2, actual_purchase_sales_tax_info.elected_country_code
      assert_equal Compliance::Countries::USA.alpha2, actual_purchase_sales_tax_info.card_country_code
      assert_equal "94117", actual_purchase_sales_tax_info.postal_code
      assert_nil actual_purchase_sales_tax_info.ip_country_code
      assert_equal Compliance::Countries::USA.alpha2, actual_purchase_sales_tax_info.country_code
      assert_equal "2.47.255.255", actual_purchase_sales_tax_info.ip_address
    end
  end

  test "purchase sales tax info does not create a purchase sales tax info entry if it already has one" do
    VCR.use_cassette("Purchase/purchase_sales_tax_info/does_not_create_a_purchase_sales_tax_info_entry_if_it_already_has_one") do
      purchase_sales_tax_info = PurchaseSalesTaxInfo.new

      purchase = create_purchase(price_cents: 100_00, chargeable: build_chargeable)
      purchase.purchase_sales_tax_info = purchase_sales_tax_info
      purchase.purchase_sales_tax_info.save!

      purchase.process!
      purchase.reload

      assert_equal purchase_sales_tax_info, purchase.purchase_sales_tax_info
    end
  end

  test "purchase sales tax info stores VAT ID on subscription when present in sales tax info" do
    product = create_subscription_product
    subscription = create_subscription(link: product, business_vat_id: nil)
    purchase = build_free_purchase(link: product, subscription:, is_original_subscription_purchase: true,
                                   country: "Ireland", business_vat_id: "IE6388047V")

    VatValidationService.stubs(:new).returns(stub(process: true))

    purchase.send(:create_sales_tax_info!)

    assert_equal "IE6388047V", subscription.reload.business_vat_id
  end

  test "purchase sales tax info handles invalid countries from GEOIP lookup for IP address" do
    VCR.use_cassette("Purchase/purchase_sales_tax_info/handles_invalid_countries_from_GEOIP_lookup_for_IP_address") do
      purchase = create_purchase(price_cents: 100_00, chargeable: build_chargeable)
      purchase.sales_tax_country_code_election = Compliance::Countries::DEU.alpha2
      purchase.country = Compliance::Countries::USA.common_name
      purchase.zip_code = "94117"
      purchase.ip_country = "Invalid country"
      purchase.ip_address = "2.47.255.255"

      purchase.process!
      purchase.reload

      actual_purchase_sales_tax_info = Purchase.last.purchase_sales_tax_info
      assert_not_nil actual_purchase_sales_tax_info
      assert_equal Compliance::Countries::DEU.alpha2, actual_purchase_sales_tax_info.elected_country_code
      assert_equal Compliance::Countries::USA.alpha2, actual_purchase_sales_tax_info.card_country_code
      assert_equal "94117", actual_purchase_sales_tax_info.postal_code
      assert_nil actual_purchase_sales_tax_info.ip_country_code
      assert_equal Compliance::Countries::USA.alpha2, actual_purchase_sales_tax_info.country_code
      assert_equal "2.47.255.255", actual_purchase_sales_tax_info.ip_address
    end
  end

  # ---- sku_custom_name_or_external_id ----

  test "sku_custom_name_or_external_id with sku returns the sku external id" do
    product = create_product
    purchase = create_purchase(link: product)
    product.skus_enabled = true
    purchase.variant_attributes << create_sku
    assert_equal Sku.last.external_id.to_s, purchase.sku_custom_name_or_external_id
  end

  test "sku_custom_name_or_external_id with sku returns the custom sku" do
    product = create_product
    purchase = create_purchase(link: product)
    product.skus_enabled = true
    purchase.variant_attributes << create_sku(custom_sku: "CUSTOMIZE")
    assert_equal "CUSTOMIZE", purchase.sku_custom_name_or_external_id
  end

  test "sku_custom_name_or_external_id without sku when product is physical and has a variant returns the variant external id" do
    product = create_product
    purchase = create_purchase(link: product)
    variant = create_variant
    product.is_physical = true
    purchase.variant_attributes << variant
    assert_equal variant.external_id, purchase.sku_custom_name_or_external_id
  end

  test "sku_custom_name_or_external_id without sku returns the link external id" do
    product = create_product
    purchase = create_purchase(link: product)
    assert_equal "pid_#{product.external_id}", purchase.sku_custom_name_or_external_id
  end

  # ---- #schedule_workflow_jobs ----

  test "#schedule_workflow_jobs does not enqueue the job to schedule workflow emails if recurring payment" do
    VCR.use_cassette("Purchase/_schedule_workflow_jobs/does_not_enqueue_the_job_to_schedule_workflow_emails_if_recurring_payment") do
      creator = create_user
      user = create_user(credit_card: create_credit_card)
      product = create_subscription_product(user: creator)
      workflow = create_workflow(seller: creator, link: product)
      post = create_installment(workflow:, published_at: Time.current)
      create_installment_rule(installment: post, delayed_delivery_time: 3.days)
      subscription = create_subscription(user:, link: product)
      create_purchase(link: product, email: user.email, is_original_subscription_purchase: true, subscription:)
      recurring_purchase = create_purchase(link: product, email: user.email, is_original_subscription_purchase: false, subscription:, purchase_state: "in_progress")

      recurring_purchase.mark_successful!

      assert_equal 0, ScheduleWorkflowEmailsWorker.jobs.size
    end
  end

  # ---- #email_digest ----

  test "#email_digest returns a HMAC digest of id and email" do
    purchase = create_purchase(email: "test@example.com")
    key = GlobalConfig.get("OBFUSCATE_IDS_CIPHER_KEY")
    token_data = "#{purchase.id}:#{purchase.email}"
    expected_digest = OpenSSL::HMAC.digest("SHA256", key, token_data)
    base64_encoded_digest = Base64.urlsafe_encode64(expected_digest)

    assert_equal base64_encoded_digest, purchase.email_digest
  end

  test "#email_digest returns nil when email is blank" do
    purchase = build_purchase(email: nil)
    assert_nil purchase.email_digest
  end

  # ---- #receipt_url ----

  test "#receipt_url returns the correct receipt URL" do
    purchase = create_purchase
    expected_url = "#{PROTOCOL}://#{DOMAIN}/purchases/#{purchase.external_id}/receipt?email=#{CGI.escape(purchase.email)}"
    assert_equal expected_url, purchase.receipt_url
  end

  # ---- email ----

  test "email on create valid email is valid" do
    purchase = build_purchase
    purchase.save
    assert purchase.valid?
  end

  test "email on create invalid email is invalid" do
    # email invalid because it contains trailing whitespace
    purchase = build_purchase(email: "hi@gumroad.com ")
    purchase.save
    assert_not purchase.valid?
  end

  test "email on update valid email is valid" do
    purchase = create_purchase
    purchase.updated_at = Time.current
    purchase.save
    assert purchase.valid?
  end

  test "email on update invalid email is valid" do
    # email invalid because it contains trailing whitespace
    purchase = build_purchase(email: "hi@gumroad.com ")
    purchase.save(validate: false)
    purchase.updated_at = Time.current
    purchase.save
    assert purchase.valid?
  end

  # ---- .counts_towards_inventory ----

  test ".counts_towards_inventory only includes purchases that could become successful" do
    reset_purchases!
    product = create_product
    success = create_purchase(link: product)
    success_preorder_auth = create_purchase(link: product, purchase_state: "preorder_authorization_successful")
    create_purchase(link: product, purchase_state: "failed")
    in_progress = create_purchase(link: product, purchase_state: "in_progress")

    assert_same_records [success, success_preorder_auth, in_progress], Purchase.counts_towards_inventory
  end

  test ".counts_towards_inventory excludes recurring charges" do
    reset_purchases!
    product = create_product
    subscription = create_subscription(link: product)
    initial_purchase = create_purchase(link: product, subscription:, is_original_subscription_purchase: true)
    create_purchase(link: product, subscription:, is_original_subscription_purchase: false)

    assert_same_records [initial_purchase], Purchase.counts_towards_inventory
  end

  test ".counts_towards_inventory excludes additional contributions" do
    reset_purchases!
    create_purchase(is_additional_contribution: true)

    assert_empty Purchase.counts_towards_inventory
  end

  test ".counts_towards_inventory excludes archived original subscription purchases" do
    reset_purchases!
    purchase = create_purchase(is_archived_original_subscription_purchase: true)

    assert_not_includes Purchase.counts_towards_inventory, purchase
  end

  test ".counts_towards_inventory memberships with tiers only counts active memberships plus non-subscription sales" do
    reset_purchases!
    non_subscription_purchase = create_purchase

    membership_product = create_membership_product
    active_subscription = create_subscription(link: membership_product)
    active_purchase = create_purchase(link: membership_product, subscription: active_subscription, is_original_subscription_purchase: true)
    inactive_subscription = create_subscription(link: membership_product, deactivated_at: Time.current)
    create_purchase(link: membership_product, subscription: inactive_subscription, is_original_subscription_purchase: true)
    non_subscription_purchase_of_membership_product = create_purchase(link: membership_product)
    free_trial_purchase = create_free_trial_membership_purchase

    assert_same_records [
      active_purchase,
      non_subscription_purchase,
      non_subscription_purchase_of_membership_product,
      free_trial_purchase,
    ], Purchase.counts_towards_inventory
  end

  # ---- .counts_towards_offer_code_uses ----

  test ".counts_towards_offer_code_uses includes successful purchases" do
    reset_purchases!
    purchase = create_purchase(purchase_state: "successful")
    assert_same_records [purchase], Purchase.counts_towards_offer_code_uses
  end

  test ".counts_towards_offer_code_uses includes preorder authorization purchases" do
    reset_purchases!
    purchase = create_preorder_authorization_purchase(link: create_product)
    assert_same_records [purchase], Purchase.counts_towards_offer_code_uses
  end

  test ".counts_towards_offer_code_uses includes original non-archived membership purchases" do
    reset_purchases!
    purchase = create_membership_purchase
    assert_same_records [purchase], Purchase.counts_towards_offer_code_uses
  end

  test ".counts_towards_offer_code_uses includes free trial membership purchases" do
    reset_purchases!
    purchase = create_free_trial_membership_purchase
    assert_same_records [purchase], Purchase.counts_towards_offer_code_uses
  end

  test ".counts_towards_offer_code_uses excludes other purchases" do
    reset_purchases!
    create_failed_purchase(link: create_product)
    create_purchase(purchase_state: "test_successful")
    create_purchase(purchase_state: "gift_receiver_purchase_successful")
    original_purchase = create_recurring_membership_purchase_with_original(is_original_subscription_purchase: false).original_purchase
    create_membership_purchase(is_archived_original_subscription_purchase: true)
    assert_equal [], Purchase.where.not(id: original_purchase.id).counts_towards_offer_code_uses.to_a
  end

  # ---- .counts_towards_volume ----

  test ".counts_towards_volume includes successful purchases" do
    reset_purchases!
    purchase = create_purchase(purchase_state: "successful")
    assert_same_records [purchase], Purchase.counts_towards_volume
  end

  test ".counts_towards_volume excludes other purchases" do
    reset_purchases!
    create_failed_purchase(link: create_product)
    create_purchase(purchase_state: "test_successful")
    create_purchase(purchase_state: "gift_receiver_purchase_successful")
    create_purchase(price_cents: 300, stripe_refunded: true)
    create_purchase(chargeback_date: Date.yesterday)
    assert_equal [], Purchase.counts_towards_volume.to_a
  end

  # ---- has_active_subscription ----

  test "has_active_subscription does not include cancelled subscriptions" do
    subscription, purchase = setup_active_subscription_purchase
    subscription.update_attribute(:cancelled_at, Time.current)
    assert_equal false, purchase.has_active_subscription?
  end

  test "has_active_subscription does not include failed subscriptions" do
    subscription, purchase = setup_active_subscription_purchase
    subscription.update_attribute(:failed_at, Time.current)
    assert_equal false, purchase.has_active_subscription?
  end

  test "has_active_subscription does not include ended subscriptions" do
    subscription, purchase = setup_active_subscription_purchase
    subscription.update_attribute(:ended_at, Time.current)
    assert_equal false, purchase.has_active_subscription?
  end

  test "has_active_subscription does not include pending cancellation subscriptions" do
    subscription, purchase = setup_active_subscription_purchase
    subscription.update_attribute(:cancelled_at, 1.hour.from_now)
    assert_equal false, purchase.has_active_subscription?
  end

  # ---- #charge_discover_fee? ----

  test "#charge_discover_fee? is false if the purchase is not recommended" do
    purchase = create_purchase(was_product_recommended: false)
    assert_equal false, purchase.charge_discover_fee?
  end

  test "#charge_discover_fee? returns true if the purchase is recommended" do
    purchase = create_purchase(was_product_recommended: false)
    purchase.was_product_recommended = true
    purchase.save
    assert_equal true, purchase.charge_discover_fee?
    purchase.seller.recommendation_type = User::RecommendationType::NO_RECOMMENDATIONS
    purchase.seller.save
    assert_equal true, purchase.charge_discover_fee?
  end

  test "#charge_discover_fee? returns false if the purchase is recommended by library or more like this" do
    purchase = create_purchase(was_product_recommended: false)
    assert_equal false, purchase.charge_discover_fee?

    purchase.update!(was_product_recommended: true)
    assert_equal true, purchase.charge_discover_fee?

    RecommendationType.all.each do |recommendation_type|
      purchase.update!(recommended_by: recommendation_type)
      assert_equal true, purchase.was_product_recommended?
      assert_equal !RecommendationType.is_free_recommendation_type?(recommendation_type), purchase.charge_discover_fee?
    end
  end

  # ---- paypal purchase failure ----

  test "paypal purchase failure emails the buyer saying the purchase failed" do
    VCR.use_cassette("Purchase/paypal_purchase_failure/emails_the_buyer_saying_the_purchase_failed") do
      purchase = build_paypal_in_progress_purchase
      purchase.process!

      mail_double = mock("mail")
      mail_double.stubs(:deliver_later)
      CustomerMailer.expects(:paypal_purchase_failed).returns(mail_double)
      purchase.mark_failed
    end
  end

  test "paypal purchase failure emails the buyer saying the purchase failed for native paypal too" do
    VCR.use_cassette("Purchase/paypal_purchase_failure/emails_the_buyer_saying_the_purchase_failed_for_native_paypal_too") do
      purchase = build_paypal_in_progress_purchase
      purchase.process!

      purchase.charge_processor_id = "paypal"
      mail_double = mock("mail")
      mail_double.stubs(:deliver_later)
      CustomerMailer.expects(:paypal_purchase_failed).returns(mail_double)
      purchase.mark_failed
    end
  end

  test "paypal purchase failure doesn't email the buyer if not a paypal purchase" do
    VCR.use_cassette("Purchase/paypal_purchase_failure/doesn_t_email_the_buyer_if_not_a_paypal_purchase") do
      purchase = build_paypal_in_progress_purchase
      purchase.process!

      assert_no_difference -> { ActionMailer::Base.deliveries.count } do
        purchase.mark_failed
      end
    end
  end

  # ---- #upload_invoice_pdf ----

  # No cassette exists: the S3 hosts are VCR-ignored, and the Minitest suite has
  # no S3 service (see test_helper). The RSpec spec stubbed the bucket/object and
  # did a real put to gumroad-specs; here the S3 object's network ops (put,
  # content_length) are stubbed so the contract is verified without S3.
  test "#upload_invoice_pdf writes the passed file to S3 and returns the S3 object" do
    purchase = create_purchase
    file = File.open(Rails.root.join("spec", "support", "fixtures", "smaller.png"))

    s3_object = mock("s3_object")
    # The method's contract is "write the passed file to S3, return the object". Assert the
    # write actually happens with the file as the body. (The RSpec original verified this via a
    # real gumroad-specs round-trip + a content_length read; the Minitest CI job has no S3, so
    # pin the write with a mock expectation — stubbing :put would let a deleted put() pass.)
    s3_object.expects(:put).with(body: file)
    s3_bucket_double = mock("s3_bucket")
    s3_bucket_double.expects(:object).returns(s3_object)
    s3_resource_double = mock("s3_resource")
    s3_resource_double.stubs(:bucket).with(INVOICES_S3_BUCKET).returns(s3_bucket_double)
    Aws::S3::Resource.stubs(:new).returns(s3_resource_double)

    result = purchase.upload_invoice_pdf(file)
    assert_same s3_object, result
  end

  # ---- #unsubscribe_buyer ----

  test "#unsubscribe_buyer unsubcribes the buyer of the purchase from all sales made by the seller" do
    setup_unsubscribe_buyer

    before_state = unsubscribe_state
    assert_equal [true, true, true, true, true], before_state

    @purchase_of_product_1.unsubscribe_buyer

    assert_equal [false, false, true, false, true], unsubscribe_state
  end

  test "#unsubscribe_buyer when purchase record is invalid unsubscribes the buyer without running validations" do
    setup_unsubscribe_buyer
    @purchase_of_product_1.update_column(:price_cents, nil)
    assert_equal false, @purchase_of_product_1.valid? # Ensure that the record currently fails validation

    Rails.logger.stubs(:info)
    Rails.logger.expects(:info).with("Could not update purchase (#{@purchase_of_product_1.id}) with validations turned on. Unsubscribing the buyer without running validations.")

    assert_equal true, @purchase_of_product_1.reload.can_contact
    @purchase_of_product_1.unsubscribe_buyer
    assert_equal false, @purchase_of_product_1.reload.can_contact
  end

  # ---- #toggle_off_can_contact_if_buyer_has_unsubscribed ----

  test "#toggle_off_can_contact_if_buyer_has_unsubscribed when customer has previously unsubscribed sets can_contact to false on new purchases automatically" do
    setup_previously_unsubscribed
    new_purchase = create_purchase(link: @product_2, email: @buyer_email, seller: @seller)

    assert_equal false, new_purchase.can_contact
  end

  test "#toggle_off_can_contact_if_buyer_has_unsubscribed when customer has previously unsubscribed does not add the customer to AudienceMember for the new purchase" do
    setup_previously_unsubscribed
    assert_nil AudienceMember.find_by(email: @buyer_email, seller: @seller)

    create_purchase(link: @product_2, email: @buyer_email, seller: @seller)

    assert_nil AudienceMember.find_by(email: @buyer_email, seller: @seller)
  end

  test "#toggle_off_can_contact_if_buyer_has_unsubscribed when customer has previously unsubscribed prevents the customer from appearing in email blast audience" do
    setup_previously_unsubscribed
    installment = create_installment(seller: @seller, installment_type: "audience")
    create_purchase(link: @product_2, email: @buyer_email, seller: @seller)

    assert_empty AudienceMember.filter(seller_id: @seller.id, params: installment.audience_members_filter_params).where(email: @buyer_email)
  end

  test "#toggle_off_can_contact_if_buyer_has_unsubscribed when customer has not previously unsubscribed allows new purchases to have can_contact true" do
    seller = create_user
    buyer_email = "buyer@example.com"
    product_2 = create_product(user: seller)
    new_purchase = create_purchase(link: product_2, email: buyer_email, seller:)
    assert_equal true, new_purchase.can_contact
    assert AudienceMember.find_by(email: buyer_email, seller:).present?
  end

  test "#toggle_off_can_contact_if_buyer_has_unsubscribed when customer has not previously unsubscribed allows the customer to appear in email blast audience" do
    seller = create_user
    buyer_email = "buyer@example.com"
    product_2 = create_product(user: seller)
    installment = create_installment(seller:, installment_type: "audience")
    create_purchase(link: product_2, email: buyer_email, seller:)

    assert AudienceMember.filter(seller_id: seller.id, params: installment.audience_members_filter_params).where(email: buyer_email).present?
  end

  # ---- #attach_credit_card_to_purchaser ----

  test "#attach_credit_card_to_purchaser the method is not called when the purchaser_id is not updated" do
    user = create_user
    subscription = create_subscription(user:)
    purchase = create_purchase(purchaser: user, subscription:, is_original_subscription_purchase: true)

    purchase.expects(:attach_credit_card_to_purchaser).never

    purchase.email = "buyer-#{unique_suffix}@example.com"
    purchase.save!
  end

  test "#attach_credit_card_to_purchaser the method is not called when the purchaser_id is set to nil" do
    user = create_user
    subscription = create_subscription(user:)
    purchase = create_purchase(purchaser: user, subscription:, is_original_subscription_purchase: true)

    purchase.expects(:attach_credit_card_to_purchaser).never

    purchase.purchaser_id = nil
    purchase.save!
  end

  test "#attach_credit_card_to_purchaser the method is not called for non-subscription purchases" do
    purchase = create_purchase(purchaser: create_user)

    purchase.expects(:attach_credit_card_to_purchaser).never

    purchase.purchaser_id = create_user.id
    purchase.save!
  end

  test "#attach_credit_card_to_purchaser when changing the purchaser id when feature is disabled does not call the method" do
    user = create_user
    subscription = create_subscription(user:)
    purchase = create_purchase(purchaser: user, subscription:, is_original_subscription_purchase: true)

    purchase.expects(:attach_credit_card_to_purchaser).never

    purchase.purchaser_id = create_user.id
    purchase.save!
  end

  test "#attach_credit_card_to_purchaser when changing the purchaser id when feature is enabled calls the method" do
    Feature.activate(:attach_credit_card_to_purchaser)
    user = create_user
    subscription = create_subscription(user:)
    purchase = create_purchase(purchaser: user, subscription:, is_original_subscription_purchase: true)

    assert_receives_and_calls_original(purchase, :attach_credit_card_to_purchaser) do
      purchase.purchaser_id = create_user.id
      purchase.save!
    end
  end

  test "#attach_credit_card_to_purchaser when changing the purchaser id when feature is enabled attaches the credit card of the latest successful purchase to the purchaser" do
    VCR.use_cassette("Purchase/_attach_credit_card_to_purchaser/when_changing_the_purchaser_id/when_attach_credit_card_to_purchaser_feature_is_enabled/attaches_the_credit_card_of_the_latest_successful_purchase_to_the_purchaser") do
      Feature.activate(:attach_credit_card_to_purchaser)
      user = create_user
      subscription = create_subscription(user:)

      latest_eligible_cc = create_credit_card

      purchase = create_purchase(subscription:, credit_card: create_credit_card,
                                 is_original_subscription_purchase: true, created_at: 30.minutes.ago)
      create_purchase(purchaser: user, credit_card: create_credit_card, created_at: 25.minutes.ago)
      create_purchase(purchaser: user, credit_card: latest_eligible_cc, created_at: 20.minutes.ago)
      create_purchase(purchaser: user, created_at: 15.minutes.ago)
      create_purchase(purchaser: user, purchase_state: "failed", credit_card: create_credit_card, created_at: 10.minutes.ago)
      create_purchase(credit_card: create_credit_card, created_at: 5.minutes.ago)

      assert_nil user.reload.credit_card

      assert_receives_and_calls_original(purchase, :attach_credit_card_to_purchaser) do
        purchase.purchaser = user
        purchase.save!
      end

      assert_equal latest_eligible_cc, user.reload.credit_card
    end
  end

  test "#attach_credit_card_to_purchaser when changing the purchaser id when feature is enabled does not attempt to attach a credit card to the purchaser if one already exists" do
    VCR.use_cassette("Purchase/_attach_credit_card_to_purchaser/when_changing_the_purchaser_id/when_attach_credit_card_to_purchaser_feature_is_enabled/does_not_attempt_to_attach_a_credit_card_to_the_purchaser_if_one_already_exists") do
      Feature.activate(:attach_credit_card_to_purchaser)
      subscription = create_subscription(user: create_user)

      user = create_user(credit_card: create_credit_card)
      purchase = create_purchase(subscription:, credit_card: create_credit_card,
                                 is_original_subscription_purchase: true)

      before_cc = user.reload.credit_card
      assert_receives_and_calls_original(purchase, :attach_credit_card_to_purchaser) do
        purchase.purchaser = user
        purchase.save!
      end
      assert_equal before_cc, user.reload.credit_card
    end
  end

  # ---- #update_rental_expired ----

  test "#update_rental_expired updates rental_expired field if is_rental is set to false" do
    purchase = create_purchase(is_rental: true, rental_expired: true)
    purchase.is_rental = false
    purchase.save!
    assert_nil purchase.rental_expired
  end

  # ---- .formatted_error_code ----

  test ".formatted_error_code falls back to purchase.stripe_error_code" do
    purchase = create_purchase(stripe_error_code: "error_code")
    assert_equal "Error Code", purchase.formatted_error_code
  end

  test ".formatted_error_code falls back to purchase.error_code if purchase.stripe_error_code is empty" do
    purchase = create_purchase(stripe_error_code: nil, error_code: "stripe_error_code")
    assert_equal "Stripe Error Code", purchase.formatted_error_code
  end

  test ".formatted_error_code displays corresponding stripe message for purchase.stripe_error_code" do
    purchase = create_purchase(
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      stripe_error_code: "card_declined_do_not_honor")
    assert_equal PurchaseErrorCode::STRIPE_ERROR_CODES["do_not_honor"], purchase.formatted_error_code
  end

  test ".formatted_error_code displays corresponding paypal message for purchase.stripe_error_code" do
    purchase = create_purchase(
      charge_processor_id: BraintreeChargeProcessor.charge_processor_id,
      stripe_error_code: "2000")
    assert_equal PurchaseErrorCode::PAYPAL_ERROR_CODES["2000"], purchase.formatted_error_code
  end

  test ".formatted_error_code displays corresponding paypal message for purchase.stripe_error_code in case of paypal connect" do
    # A native-PayPal purchase carries the payer's email in card_visual (the base
    # :purchase factory derives this from the charge processor); the fraud check
    # parses it as an email address, so it must be a real address, not a card mask.
    purchase = create_purchase(
      charge_processor_id: PaypalChargeProcessor.charge_processor_id,
      card_type: CardType::PAYPAL,
      card_visual: "jane@paypal.com",
      stripe_error_code: PurchaseErrorCode::PAYPAL_PAYER_CANCELLED_BILLING_AGREEMENT)
    assert_equal PurchaseErrorCode::PAYPAL_ERROR_CODES[PurchaseErrorCode::PAYPAL_PAYER_CANCELLED_BILLING_AGREEMENT], purchase.formatted_error_code
  end

  # ---- #has_payment_error? ----

  test "#has_payment_error? returns true if stripe_error_code is present" do
    purchase = build_purchase(stripe_error_code: "foo")
    assert_equal true, purchase.has_payment_error?
  end

  test "#has_payment_error? returns true if error_code is a payment error code" do
    PurchaseErrorCode::PAYMENT_ERROR_CODES.each do |error_code|
      purchase = build_purchase(error_code:)
      assert_equal true, purchase.has_payment_error?
    end
  end

  test "#has_payment_error? returns true if the purchase has failed" do
    purchase = build_purchase(purchase_state: "failed")
    assert_equal true, purchase.has_payment_error?
  end

  test "#has_payment_error? returns false if error_code is a non-payment error code" do
    purchase = build_purchase(error_code: "foo")
    assert_equal false, purchase.has_payment_error?
  end

  test "#has_payment_error? returns false if error_code and stripe_error_code are not present" do
    purchase = build_purchase
    assert_equal false, purchase.has_payment_error?
  end

  # ---- #has_payment_network_error? ----

  test "#has_payment_network_error? returns true if error_code is a STRIPE_UNAVAILABLE error" do
    purchase = build_purchase(error_code: PurchaseErrorCode::STRIPE_UNAVAILABLE)
    assert_equal true, purchase.has_payment_network_error?
  end

  test "#has_payment_network_error? returns true if error_code is a PAYPAL_UNAVAILABLE error" do
    purchase = build_purchase(error_code: PurchaseErrorCode::PAYPAL_UNAVAILABLE)
    assert_equal true, purchase.has_payment_network_error?
  end

  test "#has_payment_network_error? returns true if stripe_error_code is a PROCESSING_ERROR error" do
    purchase = build_purchase(stripe_error_code: PurchaseErrorCode::PROCESSING_ERROR)
    assert_equal true, purchase.has_payment_network_error?
  end

  test "#has_payment_network_error? returns true if error_code is PROCESSOR_INVALID_REQUEST, keeping subscription/preorder retries so a fixed deploy bug can self-heal" do
    purchase = build_purchase(error_code: PurchaseErrorCode::PROCESSOR_INVALID_REQUEST)
    assert_equal true, purchase.has_payment_network_error?
  end

  test "#has_payment_network_error? returns false if error_code or stripe_error_code are other errors" do
    purchase = build_purchase(error_code: "foo")
    assert_equal false, purchase.has_payment_network_error?

    purchase = build_purchase(stripe_error_code: "foo")
    assert_equal false, purchase.has_payment_network_error?
  end

  test "#has_payment_network_error? returns false if error_code and stripe_error_code are absent" do
    purchase = build_purchase
    assert_equal false, purchase.has_payment_network_error?
  end

  # ---- #has_retryable_payment_error? ----

  test "#has_retryable_payment_error? returns true if stripe_error_code is STRIPE_INSUFFICIENT_FUNDS error" do
    purchase = build_purchase(stripe_error_code: PurchaseErrorCode::STRIPE_INSUFFICIENT_FUNDS)
    assert_equal true, purchase.has_retryable_payment_error?
  end

  test "#has_retryable_payment_error? returns false if stripe_error_code is a different error" do
    purchase = build_purchase(stripe_error_code: PurchaseErrorCode::PROCESSING_ERROR)
    assert_equal false, purchase.has_retryable_payment_error?
  end

  test "#has_retryable_payment_error? returns false is stripe_error_code is nil" do
    purchase = build_purchase
    assert_equal false, purchase.has_retryable_payment_error?
  end

  # =========================== from part 5 ===========================
  test "#tiers for a non-tiered membership purchase returns an empty array" do
    purchase = create_purchase
    assert_equal [], purchase.tiers
  end

  test "#tiers for a tiered membership product that is associated with a tier returns an array containing the tier" do
    product = create_membership_product_with_preset_tiered_pricing
    second_tier = product.tiers.find_by(name: "Second Tier")
    purchase = create_purchase(link: product, variant_attributes: [second_tier])
    assert_equal [second_tier], purchase.tiers
  end

  test "#tiers for a tiered membership product that is not associated with a tier returns an array containing the default tier" do
    product = create_membership_product_with_preset_tiered_pricing
    default_tier = product.default_tier
    purchase = create_purchase(link: product)
    assert_equal [default_tier], purchase.tiers
  end

  # --- #show_view_content_button_on_product_page? ----------------------------

  test "#show_view_content_button_on_product_page? returns true for a tiered membership product with a url redirect" do
    purchase = create_membership_purchase(link: create_membership_product)
    purchase.create_url_redirect!

    assert_equal true, purchase.show_view_content_button_on_product_page?
  end

  test "#show_view_content_button_on_product_page? returns true if product has attached files" do
    purchase = create_purchase(link: create_product_with_files, purchase_state: "in_progress")
    purchase.process!
    purchase.update_balance_and_mark_successful!

    assert_equal 2, purchase.link.alive_product_files.count
    assert_equal true, purchase.show_view_content_button_on_product_page?
  end

  test "#show_view_content_button_on_product_page? returns true even if product has no attached files" do
    purchase = create_purchase(link: create_product, purchase_state: "in_progress")
    purchase.process!
    purchase.update_balance_and_mark_successful!

    assert_equal 0, purchase.link.alive_product_files.count
    assert_equal true, purchase.show_view_content_button_on_product_page?
  end

  # --- #downcase_email -------------------------------------------------------

  test "#downcase_email downcases the email when validating" do
    purchase = build_purchase(email: "AbC@def.coM")
    purchase.valid?
    assert_equal "abc@def.com", purchase.email

    purchase.email = "FOO@BAR.com"
    purchase.save!
    assert_equal "foo@bar.com", purchase.email
  end

  # --- charge_card! ----------------------------------------------------------

  test "charge_card! adds proper error code to purchase if creator's paypal account is restricted and cannot accept payment" do
    User.any_instance.stubs(:native_paypal_payment_enabled?).returns(true)
    paypal_create_order_failure_response = JSON.parse({ status_code: 422,
                                                        result: { name: "UNPROCESSABLE_ENTITY",
                                                                  details: [{
                                                                    field: "/purchase_units/@reference_id=='p0mBFkazbToLRRXTaRgTFw=='/payee",
                                                                    location: "body",
                                                                    issue: "PAYEE_ACCOUNT_RESTRICTED",
                                                                    description: "The merchant account is restricted." }],
                                                                  message: "The requested action could not be performed, semantically incorrect, or failed business validation.",
                                                                  debug_id: "e371fa4eaa124",
                                                                  links: [{
                                                                    href: "https://developer.paypal.com/docs/api/orders/v2/#error-PAYEE_ACCOUNT_RESTRICTED",
                                                                    rel: "information_link",
                                                                    method: "GET" }]
                                                        }
                                                      }.to_json, object_class: OpenStruct)
    PaypalRestApi.any_instance.stubs(:create_order).returns(paypal_create_order_failure_response)

    purchase = create_purchase(charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                               card_type: CardType::PAYPAL,
                               card_visual: "jane@paypal.com",
                               merchant_account: create_merchant_account_paypal(charge_processor_merchant_id: "CJS32DZ7NDN5L"),
                               chargeable: build_native_paypal_chargeable)

    purchase.process!

    assert purchase.errors.present?
    assert_equal "There is a problem with creator's PayPal account, please try again later (your card was not charged).", purchase.errors[:base].first
    assert_equal PurchaseErrorCode::PAYPAL_MERCHANT_ACCOUNT_RESTRICTED, purchase.stripe_error_code
  end

  # --- #original_purchase ----------------------------------------------------

  test "#original_purchase returns the original subscription purchase" do
    original_purchase = create_membership_purchase(is_archived_original_subscription_purchase: true)
    purchase = create_purchase(link: original_purchase.link, subscription: original_purchase.subscription, is_original_subscription_purchase: true)
    assert_equal purchase, purchase.reload.original_purchase
  end

  test "#original_purchase returns itself when not a subscription" do
    purchase = create_purchase
    assert_equal purchase, purchase.original_purchase
  end

  test "#original_purchase returns itself when it's the original purchase" do
    purchase = create_membership_purchase
    assert_equal purchase, purchase.original_purchase
  end

  # --- #true_original_purchase -----------------------------------------------

  test "#true_original_purchase returns the (true) original subscription purchase" do
    original_purchase = create_membership_purchase(is_archived_original_subscription_purchase: true)
    purchase = create_purchase(link: original_purchase.link, subscription: original_purchase.subscription, is_original_subscription_purchase: true)
    assert_equal original_purchase, purchase.reload.true_original_purchase
  end

  test "#true_original_purchase returns itself when not a subscription" do
    purchase = create_purchase
    assert_equal purchase, purchase.true_original_purchase
  end

  test "#true_original_purchase returns itself when it's the original purchase" do
    purchase = create_membership_purchase
    assert_equal purchase, purchase.true_original_purchase
  end

  # --- double charge check ---------------------------------------------------

  test "double charge check when product doesn't have variants doesn't create duplicate purchase" do
    product = create_product
    params = { link: product, ip_address: "1.1.1.1", email: "gumroad@example.com" }
    create_purchase(**params)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      create_purchase(**params)
    end
    assert_match(/You have already paid for this product. It has been emailed to you./, error.message)
  end

  test "double charge check when product doesn't have variants after 3 minutes allows to create duplicate purchase" do
    product = create_product
    params = { link: product, ip_address: "1.1.1.1", email: "gumroad@example.com" }
    create_purchase(**params)

    travel_to(3.minutes.from_now) do
      assert_difference -> { Purchase.successful.count }, 1 do
        create_purchase(**params)
      end
    end
  end

  test "double charge check when product has variants allows to create purchases when the previously bought product is of a different variant" do
    product = create_product
    params = { link: product, ip_address: "1.1.1.1", email: "gumroad@example.com" }
    variant_category = create_variant_category(link: product)
    variant1 = create_variant(variant_category:)
    variant2 = create_variant(variant_category:)
    create_purchase(**params.merge(variant_attributes: [variant1]))

    assert_difference -> { Purchase.successful.count }, 1 do
      create_purchase(**params.merge(variant_attributes: [variant2]))
    end

    assert_difference -> { Purchase.successful.count }, 1 do
      create_purchase(**params.merge(variant_attributes: [variant1, variant2]))
    end
  end

  test "double charge check when product has variants doesn't create duplicate purchase when the previously bought product is of same variant" do
    product = create_product
    params = { link: product, ip_address: "1.1.1.1", email: "gumroad@example.com" }
    variant_category = create_variant_category(link: product)
    variant1 = create_variant(variant_category:)
    create_variant(variant_category:)
    create_purchase(**params.merge(variant_attributes: [variant1]))

    error = assert_raises(ActiveRecord::RecordInvalid) do
      create_purchase(**params.merge(variant_attributes: [variant1]))
    end
    assert_match(/You have already paid for this product. It has been emailed to you./, error.message)
  end

  test "double charge check when product has variants after 3 minutes allows to create duplicate purchase of same variant" do
    product = create_product
    params = { link: product, ip_address: "1.1.1.1", email: "gumroad@example.com" }
    variant_category = create_variant_category(link: product)
    variant1 = create_variant(variant_category:)
    create_variant(variant_category:)
    create_purchase(**params.merge(variant_attributes: [variant1]))

    travel_to(3.minutes.from_now) do
      assert_difference -> { Purchase.successful.count }, 1 do
        create_purchase(**params.merge(variant_attributes: [variant1]))
      end
    end
  end

  # --- #charge_processor_unavailable_error -----------------------------------

  test "#charge_processor_unavailable_error returns STRIPE_UNAVAILABLE error if charge_processor_id is nil" do
    purchase = build_purchase(charge_processor_id: nil)
    assert_equal PurchaseErrorCode::STRIPE_UNAVAILABLE, purchase.send(:charge_processor_unavailable_error)
  end

  test "#charge_processor_unavailable_error returns STRIPE_UNAVAILABLE error if charge_processor_id is Stripe" do
    purchase = create_purchase(charge_processor_id: StripeChargeProcessor.charge_processor_id)
    assert_equal PurchaseErrorCode::STRIPE_UNAVAILABLE, purchase.send(:charge_processor_unavailable_error)
  end

  test "#charge_processor_unavailable_error returns PAYPAL_UNAVAILABLE error if charge_processor_id is Paypal" do
    # A PayPal purchase derives paypal_email from card_visual (the fraud-domain
    # check parses it as an email), so mirror the factory's PayPal card_visual.
    purchase = create_purchase(charge_processor_id: PaypalChargeProcessor.charge_processor_id, card_type: CardType::PAYPAL, card_visual: "jane@paypal.com")
    assert_equal PurchaseErrorCode::PAYPAL_UNAVAILABLE, purchase.send(:charge_processor_unavailable_error)
  end

  test "#charge_processor_unavailable_error returns PAYPAL_UNAVAILABLE error if charge_processor_id is Braintree" do
    purchase = create_purchase(charge_processor_id: BraintreeChargeProcessor.charge_processor_id)
    assert_equal PurchaseErrorCode::PAYPAL_UNAVAILABLE, purchase.send(:charge_processor_unavailable_error)
  end

  # --- #not_charged_and_not_free_trial? --------------------------------------

  test "#not_charged_and_not_free_trial? with not_charged purchase state returns true for a non-free trial purchase" do
    purchase = build_purchase(purchase_state: "not_charged")
    assert_equal true, purchase.not_charged_and_not_free_trial?
  end

  test "#not_charged_and_not_free_trial? with not_charged purchase state returns false for a free trial purchase" do
    purchase = build_purchase(purchase_state: "not_charged", is_free_trial_purchase: true)
    assert_equal false, purchase.not_charged_and_not_free_trial?
  end

  test "#not_charged_and_not_free_trial? with other purchase states returns false" do
    ["successful", "failed"].each do |purchase_state|
      purchase = build_purchase(purchase_state:)
      assert_equal false, purchase.not_charged_and_not_free_trial?
    end
  end

  # --- #paypal_refund_expired? -----------------------------------------------

  test "#paypal_refund_expired? returns true for PayPal purchases that are more than 6 months old" do
    paypal_purchase = create_purchase(created_at: 7.months.ago, card_type: CardType::PAYPAL)
    assert_equal true, paypal_purchase.paypal_refund_expired?
  end

  test "#paypal_refund_expired? returns false for PayPal purchases that are 6 months old or younger" do
    paypal_purchase = create_purchase(created_at: 7.months.ago, card_type: CardType::PAYPAL)
    paypal_purchase.created_at = 1.months.ago
    assert_equal false, paypal_purchase.paypal_refund_expired?
  end

  test "#paypal_refund_expired? returns false for non-PayPal purchases" do
    paypal_purchase = create_purchase(created_at: 7.months.ago, card_type: CardType::PAYPAL)
    paypal_purchase.card_type = nil
    assert_equal false, paypal_purchase.paypal_refund_expired?
  end

  # --- #refunding_amount_cents -----------------------------------------------

  test "#refunding_amount_cents when amount contains .99 refunds the full amount when argument is a string" do
    product = create_product(user: create_user, price_cents: 19_99)
    purchase = create_purchase(link: product, seller: product.user)
    assert_equal 19_99, purchase.refunding_amount_cents("19.99")
  end

  test "#refunding_amount_cents when amount contains .99 refunds the full amount when argument is a float" do
    product = create_product(user: create_user, price_cents: 19_99)
    purchase = create_purchase(link: product, seller: product.user)
    assert_equal 19_99, purchase.refunding_amount_cents(19.99)
  end

  test "#refunding_amount_cents when amount is fixed refunds the full amount when argument is a string" do
    product = create_product(user: create_user, price_cents: 10_00)
    purchase = create_purchase(link: product, seller: product.user)
    assert_equal 10_00, purchase.refunding_amount_cents("10")
  end

  test "#refunding_amount_cents when amount is fixed refunds the full amount when argument is a float" do
    product = create_product(user: create_user, price_cents: 10_00)
    purchase = create_purchase(link: product, seller: product.user)
    assert_equal 10_00, purchase.refunding_amount_cents(10.0)
  end

  test "#refunding_amount_cents when amount is in the thousands refunds the full amount when argument is a string" do
    product = create_product(user: create_user, price_cents: 4000_05)
    purchase = create_purchase(link: product, seller: product.user)
    assert_equal 4000_05, purchase.refunding_amount_cents("4000.05")
  end

  test "#refunding_amount_cents when amount is in the thousands refunds the full amount when argument is a float" do
    product = create_product(user: create_user, price_cents: 4000_05)
    purchase = create_purchase(link: product, seller: product.user)
    assert_equal 4000_05, purchase.refunding_amount_cents(4_000.05)
  end

  test "#refunding_amount_cents for JPY converts JPY partial refund amount to correct USD cents" do
    product = create_product(user: create_user, price_cents: 3759, price_currency_type: "jpy")
    purchase = create_purchase(link: product, seller: product.user, displayed_price_currency_type: "jpy", rate_converted_to_usd: "153.3446")
    assert_equal (5764 / 153.3446 * 100).round, purchase.refunding_amount_cents("5764")
  end

  test "#refunding_amount_cents for JPY converts JPY full refund amount to match price_cents" do
    price_cents = 3759
    product = create_product(user: create_user, price_cents:, price_currency_type: "jpy")
    purchase = create_purchase(link: product, seller: product.user, displayed_price_currency_type: "jpy", rate_converted_to_usd: "153.3446")
    jpy_full_price = (price_cents * 153.3446 / 100).round
    assert_equal price_cents, purchase.refunding_amount_cents(jpy_full_price.to_s)
  end

  # --- #original_offer_code --------------------------------------------------

  test "#original_offer_code when the offer code was deleted and include_deleted is true uses the cached offer code details" do
    product = create_product(price_cents: 500)
    offer_code = create_offer_code(products: [product], amount_cents: 400)
    purchase = create_purchase(link: product, offer_code:, price_cents: 900)
    purchase.create_purchase_offer_code_discount(offer_code:, offer_code_amount: 50, offer_code_is_percent: true, pre_discount_minimum_price_cents: 1800)
    offer_code.mark_deleted!
    assert_equal 50, purchase.original_offer_code(include_deleted: true).amount_percentage
  end

  test "#original_offer_code when the offer code was deleted but a discount is cached still applies the cached discount to the purchase price" do
    product = create_product(price_cents: 500)
    offer_code = create_offer_code(products: [product], amount_cents: 400)
    purchase = create_purchase(link: product, offer_code:, price_cents: 900)
    purchase.create_purchase_offer_code_discount(offer_code:, offer_code_amount: 50, offer_code_is_percent: true, pre_discount_minimum_price_cents: 1000)
    offer_code.mark_deleted!
    purchase.reload

    assert_equal 250, purchase.minimum_paid_price_cents
  end

  test "#original_offer_code when the offer code was deleted but a discount is cached clamps the price to zero when a cached fixed discount exceeds the price" do
    product = create_product(price_cents: 500)
    offer_code = create_offer_code(products: [product], amount_cents: 400)
    purchase = create_purchase(link: product, offer_code:, price_cents: 900)
    purchase.create_purchase_offer_code_discount(offer_code:, offer_code_amount: 600, offer_code_is_percent: false, pre_discount_minimum_price_cents: 500)
    offer_code.mark_deleted!
    purchase.reload

    assert_equal 0, purchase.minimum_paid_price_cents
  end

  test "#original_offer_code returns offer_code if the offer_code is not deleted" do
    product = create_product(price_cents: 500)
    offer_code = create_offer_code(products: [product], amount_cents: 400)
    purchase = create_purchase(link: product, offer_code:, price_cents: 900)
    assert_equal offer_code, purchase.original_offer_code
  end

  test "#original_offer_code uses the cached offer code details if present" do
    product = create_product(price_cents: 500)
    # The RSpec :offer_code factory defaults its code to "sxsw"; the shared builder
    # randomizes it, so set it explicitly to match the asserted value.
    offer_code = create_offer_code(products: [product], amount_cents: 400, code: "sxsw")
    purchase = create_purchase(link: product, offer_code:, price_cents: 900)
    purchase.create_purchase_offer_code_discount(offer_code:, offer_code_amount: 50, offer_code_is_percent: true, pre_discount_minimum_price_cents: 1800)
    assert_equal "sxsw", purchase.original_offer_code.code
    assert_equal 1800, purchase.displayed_price_cents_before_offer_code
  end

  test "#original_offer_code uses the offer code if the purchase is missing cached offer code details" do
    product = create_product(price_cents: 500)
    offer_code = create_offer_code(products: [product], amount_cents: 400)
    purchase = create_purchase(link: product, offer_code:, price_cents: 900)
    assert_equal 1300, purchase.displayed_price_cents_before_offer_code
  end

  # --- #displayed_price_cents_before_offer_code ------------------------------

  test "#displayed_price_cents_before_offer_code returns the displayed_price_cents for a purchase with no offer code" do
    product = create_product(price_cents: 500)
    purchase = build_purchase(link: product)
    assert_equal 500, purchase.displayed_price_cents_before_offer_code
  end

  test "#displayed_price_cents_before_offer_code with an offer code uses the cached offer code details if present" do
    product = create_product(price_cents: 500)
    offer_code = create_offer_code(products: [product], amount_cents: 300)
    purchase = create_purchase(link: product, offer_code:, price_cents: 900)
    purchase.create_purchase_offer_code_discount(offer_code:, offer_code_amount: 50, offer_code_is_percent: true, pre_discount_minimum_price_cents: 1800)
    assert_equal 1800, purchase.displayed_price_cents_before_offer_code
  end

  test "#displayed_price_cents_before_offer_code with an offer code uses the offer code if the purchase is missing cached offer code details" do
    product = create_product(price_cents: 500)
    offer_code = create_offer_code(products: [product], amount_cents: 300)
    purchase = create_purchase(link: product, offer_code:, price_cents: 900)
    assert_equal 1200, purchase.displayed_price_cents_before_offer_code
  end

  test "#displayed_price_cents_before_offer_code with an offer code when the offer code was deleted and include_deleted is true uses the cached offer code details" do
    product = create_product(price_cents: 500)
    offer_code = create_offer_code(products: [product], amount_cents: 300)
    purchase = create_purchase(link: product, offer_code:, price_cents: 900)
    offer_code.mark_deleted!
    purchase.create_purchase_offer_code_discount(offer_code:, offer_code_amount: 50, offer_code_is_percent: true, pre_discount_minimum_price_cents: 1800)
    assert_equal 1800, purchase.displayed_price_cents_before_offer_code(include_deleted: true)
  end

  test "#displayed_price_cents_before_offer_code with an offer code for a 100% off offer code uses the cached offer code details if present" do
    product = create_product(price_cents: 500)
    offer_code = create_offer_code(products: [product], amount_cents: 300)
    purchase = create_purchase(link: product, offer_code:, price_cents: 900)
    offer_code.update!(amount_cents: nil, amount_percentage: 100)
    purchase.update!(displayed_price_cents: 0)
    purchase.create_purchase_offer_code_discount(offer_code:, offer_code_amount: 100, offer_code_is_percent: true, pre_discount_minimum_price_cents: 1800)
    assert_equal 1800, purchase.displayed_price_cents_before_offer_code
  end

  test "#displayed_price_cents_before_offer_code with an offer code for a 100% off offer code returns nil if the purchase is missing cached offer code details" do
    product = create_product(price_cents: 500)
    offer_code = create_offer_code(products: [product], amount_cents: 300)
    purchase = create_purchase(link: product, offer_code:, price_cents: 900)
    offer_code.update!(amount_cents: nil, amount_percentage: 100)
    purchase.update!(displayed_price_cents: 0)
    assert_nil purchase.displayed_price_cents_before_offer_code
  end

  # --- #set_price_and_rate ---------------------------------------------------

  test "#set_price_and_rate caches the buyer-specific tiered discount amount" do
    seller = create_user
    buyer = create_user
    product = create_product(user: seller, price_cents: 1000)
    offer_code = set_price_and_rate_offer_code(seller:, product:)

    create_purchase(purchaser: buyer, link: product, seller:, price_cents: product.price_cents, created_at: 13.months.ago)
    purchase = build_purchase(purchaser: buyer, link: product, seller:, offer_code:)

    purchase.set_price_and_rate

    assert_equal 50, purchase.purchase_offer_code_discount.offer_code_amount
    assert_equal true, purchase.purchase_offer_code_discount.offer_code_is_percent
    assert_equal 500, purchase.displayed_price_cents
  end

  test "#set_price_and_rate rejects an existing-customer discount when the buyer does not qualify" do
    seller = create_user
    buyer = create_user
    product = create_product(user: seller, price_cents: 1000)
    offer_code = set_price_and_rate_offer_code(seller:, product:)

    purchase = build_purchase(purchaser: buyer, link: product, seller:, offer_code:)

    purchase.set_price_and_rate

    assert_includes purchase.errors.full_messages, "Sorry, this discount code is only for existing customers."
    assert_nil purchase.offer_code
    assert_nil purchase.purchase_offer_code_discount
  end

  test "#set_price_and_rate rejects a tiered discount when no tier matches the purchase" do
    seller = create_user
    buyer = create_user
    product = create_product(user: seller, price_cents: 1000)
    offer_code = set_price_and_rate_offer_code(seller:, product:)

    offer_code.update!(existing_customers_only: false, ownership_products: [])
    offer_code.update_column(:ownership_duration_tiers, [{ "months" => 12, "amount_percentage" => 50 }])
    purchase = build_purchase(purchaser: buyer, link: product, seller:, offer_code:)

    purchase.set_price_and_rate

    assert_nil purchase.offer_code
    assert_nil purchase.purchase_offer_code_discount
  end

  test "#set_price_and_rate keeps the existing-customer discount error when the purchase is saved" do
    seller = create_user
    buyer = create_user
    product = create_product(user: seller, price_cents: 1000)
    offer_code = set_price_and_rate_offer_code(seller:, product:)

    purchase = build_purchase(purchaser: buyer, link: product, seller:, offer_code:)

    purchase.set_price_and_rate
    purchase.save

    assert_includes purchase.errors.full_messages, "Sorry, this discount code is only for existing customers."
    assert_equal PurchaseErrorCode::OFFER_CODE_INVALID, purchase.error_code
    assert_nil purchase.offer_code
    assert_nil purchase.purchase_offer_code_discount
  end

  # --- associations ----------------------------------------------------------

  test "associations has many purchase_integrations returns alive and deleted purchase_integrations" do
    setup_purchase_integrations
    assert_no_difference -> { @assoc_purchase.purchase_integrations.count } do
      @circle_purchase_integration.mark_deleted!
    end
    assert_equal [@circle_integration, @discord_integration].map(&:id).sort,
                 @assoc_purchase.purchase_integrations.pluck(:integration_id).sort
  end

  test "associations has many live_purchase_integrations does not return deleted purchase_integrations" do
    setup_purchase_integrations
    assert_difference -> { @assoc_purchase.live_purchase_integrations.count }, -1 do
      @discord_purchase_integration.mark_deleted!
    end
    assert_equal [@circle_integration.id], @assoc_purchase.live_purchase_integrations.pluck(:integration_id)
  end

  test "associations has many active_integrations does not return deleted integrations" do
    setup_purchase_integrations
    assert_difference -> { @assoc_purchase.active_integrations.count }, -1 do
      @circle_purchase_integration.mark_deleted!
    end
    assert_equal [@discord_integration.id], @assoc_purchase.active_integrations.pluck(:integration_id)
  end

  test "associations has_one utm_link_driven_sale" do
    assert_equal :has_one, Purchase.reflect_on_association(:utm_link_driven_sale).macro
  end

  test "associations has_one utm_link through utm_link_driven_sale" do
    reflection = Purchase.reflect_on_association(:utm_link)
    assert_equal :has_one, reflection.macro
    assert_equal :utm_link_driven_sale, reflection.options[:through]
  end

  # --- #transcode_product_videos ---------------------------------------------

  test "#transcode_product_videos when transcode_videos_on_purchase is disabled doesn't transcode videos on purchase" do
    product = create_product_with_video_file
    product.product_files.first.update_attribute(:analyze_completed, true)
    purchase = create_purchase_in_progress(link: product)
    product.transcode_videos_on_purchase = false
    product.save!

    purchase.mark_successful!

    assert_equal 0, TranscodeVideoForStreamingWorker.jobs.size
  end

  test "#transcode_product_videos when transcode_videos_on_purchase is enabled transcodes videos and sets product.transcode_videos_on_purchase to false" do
    product = create_product_with_video_file
    product.product_files.first.update_attribute(:analyze_completed, true)
    purchase = create_purchase_in_progress(link: product)
    product.enable_transcode_videos_on_purchase!

    purchase.mark_successful!
    product_file = product.product_files.first

    assert TranscodeVideoForStreamingWorker.jobs.any? { |job| job["args"] == [product_file.id, product_file.class.name] }
    assert_equal false, product.reload.transcode_videos_on_purchase?
  end

  # --- #formatted_affiliate_credit_amount ------------------------------------

  test "#formatted_affiliate_credit_amount returns the formatted affiliate credit amount in USD" do
    Purchase.any_instance.stubs(:get_rate).returns("0.8")

    purchase = create_purchase(price_cents: 20_00,
                               affiliate: create_direct_affiliate(affiliate_basis_points: 5000),
                               displayed_price_currency_type: "gbp")

    # (20 EUR / 0.8 EUR/USD) * 0.5 cut - 1.69 (half of the fee) = $10.81
    assert_equal "$10.81", purchase.formatted_affiliate_credit_amount
  end

  # --- #format_price_in_currency ---------------------------------------------

  test "#format_price_in_currency formats the amount in the purchase's currency" do
    Purchase.any_instance.stubs(:rate_converted_to_usd).returns(0.5)

    purchase = create_purchase
    assert_equal "$5.50", purchase.format_price_in_currency(5_50)

    purchase.displayed_price_currency_type = "gbp"
    assert_equal "£2.75", purchase.format_price_in_currency(5_50)
  end

  test "#format_price_in_currency formats the amount for a subscription purchase in the purchase's currency" do
    Purchase.any_instance.stubs(:rate_converted_to_usd).returns(0.5)

    purchase = create_membership_purchase
    assert_equal "$5.50 a month", purchase.format_price_in_currency(5_50)

    purchase.displayed_price_currency_type = "eur"
    assert_equal "€2.75 a month", purchase.format_price_in_currency(5_50)
  end

  # --- #enqueue_update_sales_related_products_infos_job -----------------------

  test "#enqueue_update_sales_related_products_infos_job when the product stats has been backfilled enqueues job upon purchase success" do
    product = create_product
    purchase = create_purchase_with_balance(link: product)
    assert UpdateSalesRelatedProductsInfosJob.jobs.any? { |job| job["args"] == [purchase.id, true] }
  end

  # --- #free_purchase? -------------------------------------------------------

  test "#free_purchase? returns true" do
    purchase = create_free_purchase(link: create_product, shipping_cents: 0)
    assert_equal true, purchase.free_purchase?
  end

  test "#free_purchase? when there is a shipping fee returns false" do
    purchase = create_free_purchase(link: create_product, shipping_cents: 100)
    assert_equal false, purchase.free_purchase?
  end

  test "#free_purchase? when there is a price returns false" do
    purchase = create_purchase
    assert_equal false, purchase.free_purchase?
  end

  # --- AudienceMember --------------------------------------------------------

  test "AudienceMember #should_be_audience_member? only returns true for expected cases" do
    VCR.use_cassette("Purchase/AudienceMember/_should_be_audience_member_/only_returns_true_for_expected_cases") do
      purchase = create_purchase
      assert_equal true, purchase.should_be_audience_member?

      [
        create_failed_purchase(link: create_product),
        create_refunded_purchase,
        create_test_purchase,
        create_purchase(can_contact: false),
        create_disputed_purchase,
        create_purchase(is_gift_sender_purchase: true),
      ].each do |p|
        assert_equal false, p.should_be_audience_member?
      end

      purchase = create_purchase(chargeback_date: Time.current, chargeback_reversed: true)
      assert_equal true, purchase.should_be_audience_member?

      purchase = create_free_trial_membership_purchase
      assert_equal true, purchase.should_be_audience_member?

      purchase = create_membership_purchase
      subscription = purchase.subscription
      assert_equal true, purchase.should_be_audience_member?

      # Even if the original purchase was refunded, or charged back, active subscriptions are still valid
      purchase.update!(stripe_refunded: true)
      assert_equal true, purchase.should_be_audience_member?
      purchase.update!(chargeback_date: Time.current)
      assert_equal true, purchase.should_be_audience_member?

      subscription.deactivate!
      assert_equal false, purchase.reload.should_be_audience_member?

      subscription.resubscribe!
      purchase.update!(is_original_subscription_purchase: false)
      assert_equal false, purchase.reload.should_be_audience_member?

      purchase.update!(is_original_subscription_purchase: true)
      subscription.update!(is_test_subscription: true)
      assert_equal false, purchase.reload.should_be_audience_member?

      subscription.update!(is_test_subscription: false)
      purchase.update!(is_archived_original_subscription_purchase: true)
      assert_equal false, purchase.reload.should_be_audience_member?
      purchase.update!(is_archived_original_subscription_purchase: false)

      purchase.update_column(:email, nil)
      assert_equal false, purchase.should_be_audience_member?
      purchase.update_column(:email, "some-invalid-email")
      assert_equal false, purchase.should_be_audience_member?
    end
  end

  test "AudienceMember #audience_member_details includes subscription cancellation and license use details" do
    purchase = create_membership_purchase
    create_license(purchase:, link: purchase.link).update!(uses: 4)
    purchase.subscription.update!(cancelled_at: 1.day.from_now)

    details = purchase.reload.audience_member_details
    assert_equal true, details[:subscription_cancelled]
    assert_equal 4, details[:license_uses]
  end

  test "AudienceMember #audience_member_details omits subscription cancellation and license use details when absent" do
    purchase = create_purchase

    details = purchase.audience_member_details
    assert_not details.key?(:subscription_cancelled)
    assert_not details.key?(:license_uses)
  end

  test "AudienceMember adds member when successful" do
    purchase = create_purchase_in_progress(link: create_product)

    assert_nil AudienceMember.find_by(email: purchase.email, seller: purchase.seller)

    assert_difference -> { AudienceMember.count }, 1 do
      purchase.update_balance_and_mark_successful!
    end

    member = AudienceMember.find_by(email: purchase.email, seller: purchase.seller)
    assert_equal 1, member.details["purchases"].size
    assert_equal purchase.audience_member_details.stringify_keys, member.details["purchases"].first

    create_purchase(link: create_product(user: purchase.seller), seller: purchase.seller, email: purchase.email)
    member.reload
    assert_equal 2, member.details["purchases"].size
  end

  test "AudienceMember removes member when uncontactable" do
    purchase = create_purchase
    create_active_follower(user: purchase.seller, email: purchase.email)
    assert_no_difference -> { AudienceMember.count } do
      purchase.update!(can_contact: false)
    end

    member = AudienceMember.find_by(email: purchase.email, seller: purchase.seller)
    assert member.details["follower"].present?
    assert_nil member.details["purchases"]
  end

  test "AudienceMember removes member when uncontactable with no other audience types" do
    purchase = create_purchase
    assert_difference -> { AudienceMember.count }, -1 do
      purchase.update!(can_contact: false)
    end

    member = AudienceMember.find_by(email: purchase.email, seller: purchase.seller)
    assert_nil member
  end

  test "AudienceMember removes member when subscription is deactivated" do
    purchase = create_membership_purchase

    assert_difference -> { AudienceMember.count }, -1 do
      purchase.subscription.deactivate!
    end

    assert_difference -> { AudienceMember.count }, 1 do
      purchase.subscription.resubscribe!
    end
  end

  test "AudienceMember recreates member when changing email" do
    purchase = create_purchase
    old_email = purchase.email
    new_email = "new@example.com"
    purchase.update!(email: new_email)

    old_member = AudienceMember.find_by(email: old_email, seller: purchase.seller)
    new_member = AudienceMember.find_by(email: new_email, seller: purchase.seller)
    assert_nil old_member
    assert new_member.present?
  end

  # --- purchasing power parity validations -----------------------------------

  test "purchasing power parity validations when the card country doesn't match the IP country adds an error" do
    VCR.use_cassette("Purchase/purchasing_power_parity_validations/when_the_card_country_doesn_t_match_the_IP_country/adds_an_error") do
      purchase = create_purchase(is_purchasing_power_parity_discounted: true, card_country: "US", ip_country: "CA", credit_card: create_credit_card)
      purchase.prepare_for_charge!
      assert_equal PurchaseErrorCode::PPP_CARD_COUNTRY_NOT_MATCHING, purchase.error_code
      assert_equal "In order to apply a purchasing power parity discount, you must use a card issued in the country you are in. Please try again with a local card, or remove the discount during checkout.", purchase.errors.full_messages.first
    end
  end

  test "purchasing power parity validations when the card country doesn't match the IP country when the seller has payment method verification disabled doesn't add an error" do
    VCR.use_cassette("Purchase/purchasing_power_parity_validations/when_the_card_country_doesn_t_match_the_IP_country/when_the_seller_has_payment_method_verification_disabled/doesn_t_add_an_error") do
      purchase = create_purchase(is_purchasing_power_parity_discounted: true, card_country: "US", ip_country: "CA", credit_card: create_credit_card)
      purchase.seller.update(purchasing_power_parity_payment_verification_disabled: true)
      purchase.prepare_for_charge!
      assert_nil purchase.error_code
      assert_empty purchase.errors
    end
  end

  # --- #prepare_merchant_account ---------------------------------------------

  test "#prepare_merchant_account adds an error if merchant account is a Brazilian Stripe Connect account and purchase has an affiliate" do
    VCR.use_cassette("Purchase/_prepare_merchant_account/adds_an_error_if_merchant_account_is_a_Brazilian_Stripe_Connect_account_and_purchase_has_an_affiliate") do
      seller = create_named_seller(check_merchant_account_is_linked: true)
      product = create_product(price_cents: 20_00, user: seller)
      purchase = build_purchase(
        link: product,
        chargeable: build_chargeable,
        affiliate: create_direct_affiliate(affiliate_basis_points: 5000),
        merchant_account: create_merchant_account_stripe_connect(user: seller, country: "BR"))

      purchase.send(:prepare_merchant_account, StripeChargeProcessor.charge_processor_id)

      assert purchase.errors[:base].present?
      assert_equal PurchaseErrorCode::BRAZILIAN_MERCHANT_ACCOUNT_WITH_AFFILIATE, purchase.error_code
      assert_equal "Affiliate sales are not currently supported for this product.", purchase.errors.full_messages.first
    end
  end

  # --- #giftee_name_or_email -------------------------------------------------

  test "#giftee_name_or_email for a non-gift purchase returns nil" do
    purchase = create_purchase
    assert_nil purchase.giftee_name_or_email
  end

  test "#giftee_name_or_email when the gift email is not hidden returns the gift email" do
    purchase = create_purchase
    gift = create_gift(giftee_email: "giftee@example.com", giftee_purchase: purchase)
    purchase.update!(is_gift_receiver_purchase: true, gift_received: gift)

    assert_equal "giftee@example.com", purchase.giftee_name_or_email
  end

  test "#giftee_name_or_email when the gift email is hidden for a gifter purchase returns the giftee's name" do
    purchase = create_purchase
    giftee_purchase = create_purchase(purchaser: create_user(name: "Gift User"))
    gift = create_gift(is_recipient_hidden: true, gifter_purchase: purchase, giftee_purchase:)
    purchase.update!(is_gift_sender_purchase: true, gift_given: gift)

    assert_equal "Gift User", purchase.giftee_name_or_email
  end

  test "#giftee_name_or_email when the gift email is hidden for a giftee purchase returns the giftee's name" do
    purchase = create_purchase
    gift = create_gift(is_recipient_hidden: true, giftee_purchase: purchase)
    purchase.update!(is_gift_receiver_purchase: true, gift_received: gift, purchaser: create_user(name: "Gift User"))

    assert_equal "Gift User", purchase.giftee_name_or_email
  end

  test "#giftee_name_or_email when the gift email is hidden when the user has not set a name falls back to the username" do
    purchase = create_purchase
    gift = create_gift(is_recipient_hidden: true, giftee_purchase: purchase)
    purchase.update!(is_gift_receiver_purchase: true, gift_received: gift, purchaser: create_user(username: "giftuser"))

    assert_equal "giftuser", purchase.giftee_name_or_email
  end

  # --- #json_data_for_mobile -------------------------------------------------

  test "#json_data_for_mobile returns purchase information" do
    seller = create_user(purchasing_power_parity_enabled: true)
    seller.update!(refund_fee_notice_shown: false)
    product = create_physical_product(user: seller, content_updated_at: Time.current)
    create_variant_category(link: product, title: "Color")
    create_variant_category(link: product, title: "Size")
    large_blue_sku = create_sku(link: product, name: "Blue - large", custom_sku: "large_blue")
    purchaser = create_user
    offer_code = create_offer_code(products: [create_product], code: "DISCOUNT10", amount_cents: 1000)
    purchase = create_physical_purchase(link: product, variant_attributes: [large_blue_sku],
                                        is_purchasing_power_parity_discounted: true, ip_country: "Latvia", purchaser:, offer_code:,
                                        affiliate: create_direct_affiliate(affiliate_basis_points: 500), price_cents: 2000, stripe_refunded: false, stripe_partially_refunded: false)
    purchase.create_purchasing_power_parity_info(factor: 0.49)
    review = create_product_review(purchase:, rating: 5)
    create_upsell(product:, seller:)
    shipment = create_shipment(purchase:, ship_state: :shipped, tracking_url: "https://shipping.example.com/1234", shipped_at: Time.current)

    json_data = purchase.link.as_json(mobile: true)
    json_data.merge!(
      {
        purchase_id: purchase.external_id,
        purchased_at: purchase.created_at,
        product_updates_data: purchase.update_json_data_for_mobile,
        user_id: purchaser.external_id,
        is_archived: purchase.is_archived,
        content_updated_at: purchase.link.content_updated_at,
        custom_delivery_url: nil, # Deprecated
        purchase_email: purchase.email,
        variants: {
          "Color - Size" => {
            is_sku: true,
            title: "Color - Size",
            selected_variant: {
              id: large_blue_sku.external_id,
              name: large_blue_sku.name,
            }
          }
        },
        amount_refundable_in_currency: purchase.amount_refundable_in_currency,
        currency_symbol: "$",
        refund_fee_notice_shown: false,
        product_rating: review.rating,
        refunded: false,
        partially_refunded: false,
        chargedback: false,
        full_name: "barnabas",
        sku_id: large_blue_sku.custom_sku,
        sku_external_id: large_blue_sku.external_id,
        quantity: purchase.quantity,
        order_id: purchase.external_id_numeric,
        shipped: true,
        tracking_url: shipment.calculated_tracking_url,
        shipping_address: {
          full_name: "barnabas",
          street_address: "123 barnabas street",
          city: "barnabasville",
          state: "CA",
          zip_code: "94114",
          country: "United States"
        },
        ppp: {
          country: "Latvia",
          discount: "51%"
        },
        offer_code: {
          code: "DISCOUNT10",
          displayed_amount_off: "$10",
        },
        affiliate: {
          amount: "$0.83",
          email: purchase.affiliate.affiliate_user.form_email,
        },
        formatted_total_price: purchase.formatted_total_price,
        purchase_daystamp: purchase.created_at.in_time_zone(purchase.seller.timezone).to_fs(:long_formatted_datetime),
      }
    )
    assert_equal json_data, purchase.json_data_for_mobile(include_sale_details: true)
  end

  test "#json_data_for_mobile uses the cached resolved discount amount for offer code display" do
    seller = create_user(purchasing_power_parity_enabled: true)
    seller.update!(refund_fee_notice_shown: false)
    product = create_physical_product(user: seller, content_updated_at: Time.current)
    create_variant_category(link: product, title: "Color")
    create_variant_category(link: product, title: "Size")
    large_blue_sku = create_sku(link: product, name: "Blue - large", custom_sku: "large_blue")
    purchaser = create_user
    offer_code = create_offer_code(products: [create_product], code: "DISCOUNT10", amount_cents: 1000)
    purchase = create_physical_purchase(link: product, variant_attributes: [large_blue_sku],
                                        is_purchasing_power_parity_discounted: true, ip_country: "Latvia", purchaser:, offer_code:,
                                        affiliate: create_direct_affiliate(affiliate_basis_points: 500), price_cents: 2000, stripe_refunded: false, stripe_partially_refunded: false)
    purchase.create_purchasing_power_parity_info(factor: 0.49)
    create_product_review(purchase:, rating: 5)
    create_upsell(product:, seller:)
    create_shipment(purchase:, ship_state: :shipped, tracking_url: "https://shipping.example.com/1234", shipped_at: Time.current)

    purchase.create_purchase_offer_code_discount(offer_code:, offer_code_amount: 50, offer_code_is_percent: true, pre_discount_minimum_price_cents: 4000)

    offer_code_data = purchase.json_data_for_mobile(include_sale_details: true)[:offer_code]
    assert_equal offer_code.code, offer_code_data[:code]
    assert_equal "50%", offer_code_data[:displayed_amount_off]
  end

  # --- price validation ------------------------------------------------------

  test "price validation purchase is a bundle product purchase doesn't add an error when the price is 0 for a non-free product" do
    purchase = create_purchase(is_bundle_product_purchase: true, price_cents: 0)
    assert_empty purchase.errors
  end

  # --- #display_referrer -----------------------------------------------------

  test "#display_referrer library purchase returns the correct referrer" do
    purchase = create_purchase
    purchase.update!(recommended_by: RecommendationType::GUMROAD_LIBRARY_RECOMMENDATION)
    assert_equal "Gumroad Library", purchase.display_referrer
  end

  test "#display_referrer discover purchase returns the correct referrer" do
    purchase = create_purchase
    purchase.update!(was_product_recommended: true)
    assert_equal "Gumroad Discover", purchase.display_referrer
  end

  test "#display_referrer direct purchase returns the correct referrer" do
    purchase = create_purchase
    purchase.update!(referrer: "direct")
    assert_equal "Direct", purchase.display_referrer
  end

  test "#display_referrer profile purchase returns the correct referrer" do
    purchase = create_purchase
    purchase.update!(referrer: "https://#{purchase.seller.username}.gumroad.com")
    assert_equal "Profile", purchase.display_referrer
  end

  test "#display_referrer common referrer purchase returns the correct referrer" do
    purchase = create_purchase
    purchase.update!(referrer: "https://facebook.com")
    assert_equal "Facebook", purchase.display_referrer
  end

  test "#display_referrer normal referrer purchase returns the correct referrer" do
    purchase = create_purchase
    purchase.update!(referrer: "https://normal.com")
    assert_equal "normal.com", purchase.display_referrer
  end

  test "#display_referrer receipt recommendation returns 'Gumroad receipt'" do
    purchase = create_purchase
    purchase.update!(was_product_recommended: true, recommended_by: RecommendationType::GUMROAD_RECEIPT_RECOMMENDATION)
    assert_equal "Gumroad Receipt", purchase.display_referrer
  end

  test "#display_referrer product page recommendation returns 'Gumroad product page'" do
    purchase = create_purchase
    purchase.update!(was_product_recommended: true, recommended_by: RecommendationType::PRODUCT_RECOMMENDATION)
    assert_equal "Gumroad Product Page", purchase.display_referrer
  end

  test "#display_referrer wishlist recommendation returns 'Gumroad wishlist'" do
    purchase = create_purchase
    purchase.update!(was_product_recommended: true, recommended_by: RecommendationType::WISHLIST_RECOMMENDATION)
    assert_equal "Gumroad Wishlist", purchase.display_referrer
  end

  test "#display_referrer more like this recommendation returns 'Gumroad product recommendations'" do
    purchase = create_purchase
    purchase.update!(was_product_recommended: true, recommended_by: RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION)
    assert_equal "Gumroad Product Recommendations", purchase.display_referrer
  end

  # --- #ppp_info -------------------------------------------------------------

  test "#ppp_info PPP-discounted purchase returns the PPP info" do
    purchase = create_purchase(ip_country: "United States")
    purchase.update!(is_purchasing_power_parity_discounted: true)
    purchase.create_purchasing_power_parity_info!(factor: 0.5)

    assert_equal({ country: "United States", discount: "50%" }, purchase.ppp_info)
  end

  test "#ppp_info non-PPP-discounted purchase returns nil" do
    purchase = create_purchase(ip_country: "United States")
    assert_nil purchase.ppp_info
  end

  # --- #linked_license -------------------------------------------------------

  test "#linked_license returns the linked license" do
    purchase = create_purchase(license: create_license, link: create_product(is_licensed: true))
    assert_equal purchase.license, purchase.linked_license
  end

  test "#linked_license gift purchase returns the giftee's license" do
    gifter_purchase = create_purchase(is_gift_sender_purchase: true)
    giftee_purchase = create_purchase(is_gift_receiver_purchase: true, license: create_license, link: create_product(is_licensed: true))
    create_gift(gifter_purchase:, giftee_purchase:)

    assert_equal giftee_purchase.license, gifter_purchase.reload.linked_license
  end

  test "#linked_license no license returns nil" do
    purchase = create_purchase
    assert_nil purchase.linked_license
  end

  # =========================== from part 6 ===========================
  test "#build_flow_of_funds_from_combined_charge returns a flow of funds object for the purchase with proper amounts based on purchase's portion in the charge" do
    VCR.use_cassette("Purchase/_build_flow_of_funds_from_combined_charge/returns_a_flow_of_funds_object_for_the_purchase_with_proper_amounts_based_on_purchase_s_portion_in_the_charge") do
      _charge, purchase1, purchase2, purchase3 = build_flow_of_funds_charge

      combined_flow_of_funds = FlowOfFunds.new(
        issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
        settled_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 125_00),
        gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 10_00),
        merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 125_00),
        merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 112_50)
      )

      flow_of_funds = purchase1.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)
      assert_equal 20_00, flow_of_funds.issued_amount.cents
      assert_equal Currency::USD, flow_of_funds.issued_amount.currency
      assert_equal 25_00, flow_of_funds.settled_amount.cents
      assert_equal Currency::CAD, flow_of_funds.settled_amount.currency
      assert_equal 2_00, flow_of_funds.gumroad_amount.cents
      assert_equal Currency::USD, flow_of_funds.gumroad_amount.currency
      assert_equal 25_00, flow_of_funds.merchant_account_gross_amount.cents
      assert_equal Currency::CAD, flow_of_funds.merchant_account_gross_amount.currency
      assert_equal 22_50, flow_of_funds.merchant_account_net_amount.cents
      assert_equal Currency::CAD, flow_of_funds.merchant_account_net_amount.currency

      flow_of_funds = purchase2.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)
      assert_equal 30_00, flow_of_funds.issued_amount.cents
      assert_equal 37_50, flow_of_funds.settled_amount.cents
      assert_equal 3_00, flow_of_funds.gumroad_amount.cents
      assert_equal 37_50, flow_of_funds.merchant_account_gross_amount.cents
      assert_equal 33_75, flow_of_funds.merchant_account_net_amount.cents
      assert_combined_charge_currencies(flow_of_funds)

      flow_of_funds = purchase3.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)
      assert_equal 50_00, flow_of_funds.issued_amount.cents
      assert_equal 62_50, flow_of_funds.settled_amount.cents
      assert_equal 5_00, flow_of_funds.gumroad_amount.cents
      assert_equal 62_50, flow_of_funds.merchant_account_gross_amount.cents
      assert_equal 56_25, flow_of_funds.merchant_account_net_amount.cents
      assert_combined_charge_currencies(flow_of_funds)
    end
  end

  test "#build_flow_of_funds_from_combined_charge returns a proper amounts based on purchase's portion in the charge when combined flow of funds has negative amounts" do
    VCR.use_cassette("Purchase/_build_flow_of_funds_from_combined_charge/returns_a_proper_amounts_based_on_purchase_s_portion_in_the_charge_when_combined_flow_of_funds_has_negative_amounts") do
      _charge, purchase1, purchase2, purchase3 = build_flow_of_funds_charge

      combined_flow_of_funds = FlowOfFunds.new(
        issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: -100_00),
        settled_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -125_00),
        gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: -10_00),
        merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -125_00),
        merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -112_50)
      )

      flow_of_funds = purchase1.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)
      assert_equal(-20_00, flow_of_funds.issued_amount.cents)
      assert_equal(-25_00, flow_of_funds.settled_amount.cents)
      assert_equal(-2_00, flow_of_funds.gumroad_amount.cents)
      assert_equal(-25_00, flow_of_funds.merchant_account_gross_amount.cents)
      assert_equal(-22_50, flow_of_funds.merchant_account_net_amount.cents)
      assert_combined_charge_currencies(flow_of_funds)

      flow_of_funds = purchase2.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)
      assert_equal(-30_00, flow_of_funds.issued_amount.cents)
      assert_equal(-37_50, flow_of_funds.settled_amount.cents)
      assert_equal(-3_00, flow_of_funds.gumroad_amount.cents)
      assert_equal(-37_50, flow_of_funds.merchant_account_gross_amount.cents)
      assert_equal(-33_75, flow_of_funds.merchant_account_net_amount.cents)
      assert_combined_charge_currencies(flow_of_funds)

      flow_of_funds = purchase3.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)
      assert_equal(-50_00, flow_of_funds.issued_amount.cents)
      assert_equal(-62_50, flow_of_funds.settled_amount.cents)
      assert_equal(-5_00, flow_of_funds.gumroad_amount.cents)
      assert_equal(-62_50, flow_of_funds.merchant_account_gross_amount.cents)
      assert_equal(-56_25, flow_of_funds.merchant_account_net_amount.cents)
      assert_combined_charge_currencies(flow_of_funds)
    end
  end

  test "#build_flow_of_funds_from_combined_charge returns proper amounts based on purchase's portion in the charge when some purchases have affiliate fees" do
    VCR.use_cassette("Purchase/_build_flow_of_funds_from_combined_charge/returns_proper_amounts_based_on_purchase_s_portion_in_the_charge_when_some_purchases_have_affiliate_fees") do
      _charge, purchase1, purchase2, purchase3 = build_flow_of_funds_charge

      combined_flow_of_funds = FlowOfFunds.new(
        issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: -100_00),
        settled_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -125_00),
        gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: -36_00),
        merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -125_00),
        merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -80_00)
      )

      purchase1.update!(affiliate_credit_cents: 6_00)
      purchase3.update!(affiliate_credit_cents: 20_00)
      purchase1.charge.update!(gumroad_amount_cents: 36_00)

      flow_of_funds = purchase1.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)
      assert_equal(-20_00, flow_of_funds.issued_amount.cents)
      assert_equal(-25_00, flow_of_funds.settled_amount.cents)
      assert_equal(-8_00, flow_of_funds.gumroad_amount.cents)
      assert_equal(-23_44, flow_of_funds.merchant_account_gross_amount.cents)
      assert_equal(-15_00, flow_of_funds.merchant_account_net_amount.cents)
      assert_combined_charge_currencies(flow_of_funds)

      flow_of_funds = purchase2.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)
      assert_equal(-30_00, flow_of_funds.issued_amount.cents)
      assert_equal(-37_50, flow_of_funds.settled_amount.cents)
      assert_equal(-3_00, flow_of_funds.gumroad_amount.cents)
      # Largest-remainder split: the three purchases' gross shares sum to exactly -125_00.
      assert_equal(-52_73, flow_of_funds.merchant_account_gross_amount.cents)
      assert_equal(-33_75, flow_of_funds.merchant_account_net_amount.cents)
      assert_combined_charge_currencies(flow_of_funds)

      flow_of_funds = purchase3.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)
      assert_equal(-50_00, flow_of_funds.issued_amount.cents)
      assert_equal(-62_50, flow_of_funds.settled_amount.cents)
      assert_equal(-25_00, flow_of_funds.gumroad_amount.cents)
      assert_equal(-48_83, flow_of_funds.merchant_account_gross_amount.cents)
      assert_equal(-31_25, flow_of_funds.merchant_account_net_amount.cents)
      assert_combined_charge_currencies(flow_of_funds)
    end
  end

  test "#build_flow_of_funds_from_combined_charge splits each amount so the per-purchase shares sum exactly to the combined charge amounts" do
    charge = create_charge(amount_cents: 100_01, gumroad_amount_cents: 10_01)

    purchase1 = create_purchase(total_transaction_cents: 33_34)
    purchase1.update!(fee_cents: 3_34)
    purchase2 = create_purchase(total_transaction_cents: 33_34)
    purchase2.update!(fee_cents: 3_34)
    purchase3 = create_purchase(total_transaction_cents: 33_33)
    purchase3.update!(fee_cents: 3_33)

    charge.purchases << purchase1
    charge.purchases << purchase2
    charge.purchases << purchase3

    combined_flow_of_funds = FlowOfFunds.new(
      issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_01),
      settled_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 125_01),
      gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 10_01),
      merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 125_01),
      merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 112_51)
    )

    flows = [purchase1, purchase2, purchase3].map { |purchase| purchase.build_flow_of_funds_from_combined_charge(combined_flow_of_funds) }

    assert_equal 100_01, flows.sum { |flow| flow.issued_amount.cents }
    assert_equal 125_01, flows.sum { |flow| flow.settled_amount.cents }
    assert_equal 10_01, flows.sum { |flow| flow.gumroad_amount.cents }
    assert_equal 125_01, flows.sum { |flow| flow.merchant_account_gross_amount.cents }
    assert_equal 112_51, flows.sum { |flow| flow.merchant_account_net_amount.cents }
  end

  # ---- #mandate_options_for_stripe ------------------------------------------

  test "#mandate_options_for_stripe returns nil for PayPal and Braintree purchases" do
    product = create_membership_product
    subscription = create_subscription(link: product)
    paypal_purchase = create_purchase(charge_processor_id: PaypalChargeProcessor.charge_processor_id, link: product, purchase_state: "in_progress",
                                      card_country: "IN", subscription:, is_original_subscription_purchase: true,
                                      card_type: CardType::PAYPAL, card_visual: "jane@paypal.com", chargeable: build_native_paypal_chargeable)
    assert_nil paypal_purchase.mandate_options_for_stripe
    braintree_purchase = create_purchase(charge_processor_id: BraintreeChargeProcessor.charge_processor_id, link: product, purchase_state: "in_progress",
                                         card_country: "IN", subscription:, is_original_subscription_purchase: true, chargeable: build_paypal_chargeable)
    assert_nil braintree_purchase.mandate_options_for_stripe
  end

  test "#mandate_options_for_stripe returns nil for Stripe purchases if card country is not India" do
    VCR.use_cassette("Purchase/_mandate_options_for_stripe/returns_nil_for_Stripe_purchases_if_card_country_is_not_India") do
      product = create_membership_product
      subscription = create_subscription(link: product)
      purchase = create_purchase(charge_processor_id: StripeChargeProcessor.charge_processor_id, link: product, purchase_state: "in_progress",
                                 card_country: "US", subscription:, is_original_subscription_purchase: true, chargeable: build_chargeable)
      assert_nil purchase.mandate_options_for_stripe
    end
  end

  test "#mandate_options_for_stripe returns nil for a multi buy purchase" do
    VCR.use_cassette("Purchase/_mandate_options_for_stripe/returns_nil_for_a_multi_buy_purchase") do
      StripeChargeablePaymentMethod.any_instance.stubs(:country).returns("IN")

      product = create_membership_product
      subscription = create_subscription(link: product)
      purchase = create_purchase(charge_processor_id: StripeChargeProcessor.charge_processor_id, link: product, purchase_state: "in_progress", subscription:,
                                 card_country: "IN", is_original_subscription_purchase: true, is_multi_buy: true, chargeable: build_chargeable)
      assert_nil purchase.mandate_options_for_stripe
    end
  end

  test "#mandate_options_for_stripe returns nil for purchases that do not require future off-session charges" do
    VCR.use_cassette("Purchase/_mandate_options_for_stripe/returns_nil_for_purchases_that_do_not_require_future_off-session_charges") do
      StripeChargeablePaymentMethod.any_instance.stubs(:country).returns("IN")

      product = create_product
      purchase = create_purchase(link: product, purchase_state: "in_progress",
                                 charge_processor_id: StripeChargeProcessor.charge_processor_id, card_country: "IN", chargeable: build_chargeable)
      assert_nil purchase.mandate_options_for_stripe
    end
  end

  test "#mandate_options_for_stripe returns correct parameter to create a mandate on Stripe for purchases that require off-session charges" do
    VCR.use_cassette("Purchase/_mandate_options_for_stripe/returns_correct_parameter_to_create_a_mandate_on_Stripe_for_purchases_that_require_off-session_charges") do
      StripeChargeablePaymentMethod.any_instance.stubs(:country).returns("IN")

      product = create_membership_product
      subscription = create_subscription(link: product)

      mandate_options = create_purchase(charge_processor_id: StripeChargeProcessor.charge_processor_id, link: product, purchase_state: "in_progress",
                                        card_country: "IN", subscription:, is_original_subscription_purchase: true, chargeable: build_chargeable).mandate_options_for_stripe

      assert mandate_options.present?
      assert_equal "maximum", mandate_options[:payment_method_options][:card][:mandate_options][:amount_type]
    end
  end

  test "#mandate_options_for_stripe caps the mandate at the undiscounted total when a limited-duration discount code was applied" do
    product = create_membership_product_with_preset_tiered_pricing
    subscription = create_subscription(link: product)
    offer_code = create_offer_code(products: [product], amount_percentage: 10, duration_in_billing_cycles: 1)
    purchase = create_purchase(charge_processor_id: StripeChargeProcessor.charge_processor_id, link: product, purchase_state: "in_progress",
                               card_country: "IN", subscription:, is_original_subscription_purchase: true,
                               offer_code:, price_cents: 100, total_transaction_cents: 105, displayed_price_cents: 100)
    purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 80, offer_code_is_percent: true,
                                                  pre_discount_minimum_price_cents: 500, duration_in_billing_cycles: 1)
    chargeable = mock("chargeable")
    chargeable.stubs(:requires_mandate?).returns(true)
    purchase.stubs(:chargeable).returns(chargeable)

    mandate_options = purchase.mandate_options_for_stripe

    # Once the single discounted cycle is over, renewals charge the full 500¢ price, so the
    # cap must cover the undiscounted total (105 * 500 / 100 = 525), not the first charge.
    assert_equal 525, mandate_options[:payment_method_options][:card][:mandate_options][:amount]
  end

  test "#mandate_options_for_stripe caps the mandate at the charged total when the discount applies to all billing cycles" do
    product = create_membership_product_with_preset_tiered_pricing
    subscription = create_subscription(link: product)
    offer_code = create_offer_code(products: [product], amount_percentage: 10)
    purchase = create_purchase(charge_processor_id: StripeChargeProcessor.charge_processor_id, link: product, purchase_state: "in_progress",
                               card_country: "IN", subscription:, is_original_subscription_purchase: true,
                               offer_code:, price_cents: 100, total_transaction_cents: 105, displayed_price_cents: 100)
    purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 80, offer_code_is_percent: true,
                                                  pre_discount_minimum_price_cents: 500)
    chargeable = mock("chargeable")
    chargeable.stubs(:requires_mandate?).returns(true)
    purchase.stubs(:chargeable).returns(chargeable)

    mandate_options = purchase.mandate_options_for_stripe

    # A discount without a billing-cycle limit applies to every renewal, so the first
    # charge's total is the correct maximum — no headroom needed.
    assert_equal 105, mandate_options[:payment_method_options][:card][:mandate_options][:amount]
  end

  test "#mandate_options_for_stripe sizes the mandate from the subscription's original purchase (not the prorated charge) for upgrade purchases" do
    product = create_membership_product_with_preset_tiered_pricing
    subscription = create_subscription(link: product)
    offer_code = create_offer_code(products: [product], amount_percentage: 10, duration_in_billing_cycles: 1)
    original_purchase = create_purchase(charge_processor_id: StripeChargeProcessor.charge_processor_id, link: product, purchase_state: "successful",
                                        card_country: "IN", subscription:, is_original_subscription_purchase: true,
                                        offer_code:, price_cents: 100, total_transaction_cents: 105, displayed_price_cents: 100)
    original_purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 80, offer_code_is_percent: true,
                                                           pre_discount_minimum_price_cents: 500, duration_in_billing_cycles: 1)
    # The upgrade purchase itself only charges a small prorated amount and carries no
    # discount record — none of its numbers should influence the mandate cap.
    upgrade_purchase = create_purchase(charge_processor_id: StripeChargeProcessor.charge_processor_id, link: product, purchase_state: "in_progress",
                                       card_country: "IN", subscription:, is_upgrade_purchase: true,
                                       price_cents: 37, total_transaction_cents: 37, displayed_price_cents: 37)
    chargeable = mock("chargeable")
    chargeable.stubs(:requires_mandate?).returns(true)
    upgrade_purchase.stubs(:chargeable).returns(chargeable)

    mandate_options = upgrade_purchase.mandate_options_for_stripe

    # Renewals bill the original purchase, whose limited-duration discount expires after
    # one cycle — so the cap scales the original total to its undiscounted equivalent
    # (105 * 500 / 100 = 525), ignoring the 37¢ prorated upgrade charge entirely.
    assert_equal 525, mandate_options[:payment_method_options][:card][:mandate_options][:amount]
  end

  test "#mandate_options_for_stripe caps an upgrade purchase's mandate at the original purchase total when there is no limited-duration discount" do
    product = create_membership_product_with_preset_tiered_pricing
    subscription = create_subscription(link: product)
    create_purchase(charge_processor_id: StripeChargeProcessor.charge_processor_id, link: product, purchase_state: "successful",
                    card_country: "IN", subscription:, is_original_subscription_purchase: true,
                    price_cents: 500, total_transaction_cents: 525, displayed_price_cents: 500)
    upgrade_purchase = create_purchase(charge_processor_id: StripeChargeProcessor.charge_processor_id, link: product, purchase_state: "in_progress",
                                       card_country: "IN", subscription:, is_upgrade_purchase: true,
                                       price_cents: 37, total_transaction_cents: 37, displayed_price_cents: 37)
    chargeable = mock("chargeable")
    chargeable.stubs(:requires_mandate?).returns(true)
    upgrade_purchase.stubs(:chargeable).returns(chargeable)

    mandate_options = upgrade_purchase.mandate_options_for_stripe

    # No discount on the original purchase means renewals charge its full total, which is
    # the correct cap — unchanged from the pre-existing upgrade behavior.
    assert_equal 525, mandate_options[:payment_method_options][:card][:mandate_options][:amount]
  end

  # ---- #is_an_off_session_charge_on_indian_card? ----------------------------

  test "#is_an_off_session_charge_on_indian_card? when card country is not India returns false if it is a regular purchase" do
    assert_equal false, create_purchase_in_progress(link: create_product).is_an_off_session_charge_on_indian_card?
  end

  test "#is_an_off_session_charge_on_indian_card? when card country is not India returns false if it is a membership purchase" do
    membership_purchase = create_purchase_in_progress(link: create_membership_product)
    assert_equal false, membership_purchase.is_an_off_session_charge_on_indian_card?
  end

  test "#is_an_off_session_charge_on_indian_card? when card country is not India returns false if it is a recurring charge and charge processor is not Stripe" do
    product = create_subscription_product
    subscription = create_subscription(link: product)
    create_purchase(subscription:, is_original_subscription_purchase: true)
    recurring_charge = create_purchase_in_progress(is_original_subscription_purchase: false,
                                                   link: product, subscription:, charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                                   card_type: CardType::PAYPAL, card_visual: "jane@paypal.com")
    assert_equal false, recurring_charge.is_an_off_session_charge_on_indian_card?
  end

  test "#is_an_off_session_charge_on_indian_card? when card country is not India returns false if it is a preorder charge and charge processor is not Stripe" do
    product = create_product(is_in_preorder_state: true)
    preorder_link = create_preorder_link(link: product)
    authorization_purchase = create_preorder_authorization_purchase(link: product)
    preorder = preorder_link.build_preorder(authorization_purchase)

    preorder_charge = create_purchase_in_progress(link: product, preorder:,
                                                  charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                                  card_type: CardType::PAYPAL, card_visual: "jane@paypal.com")
    assert_equal false, preorder_charge.is_an_off_session_charge_on_indian_card?
  end

  test "#is_an_off_session_charge_on_indian_card? when card country is not India returns false if it is a recurring charge and charge processor is Stripe" do
    product = create_subscription_product
    subscription = create_subscription(link: product)
    create_purchase(subscription:, is_original_subscription_purchase: true)
    recurring_charge = create_purchase_in_progress(is_original_subscription_purchase: false, link: product, subscription:)
    assert_equal false, recurring_charge.is_an_off_session_charge_on_indian_card?
  end

  test "#is_an_off_session_charge_on_indian_card? when card country is not India returns false if it is a preorder charge and charge processor is Stripe" do
    product = create_product(is_in_preorder_state: true)
    preorder_link = create_preorder_link(link: product)
    authorization_purchase = create_preorder_authorization_purchase(link: product)
    preorder = preorder_link.build_preorder(authorization_purchase)

    preorder_charge = create_purchase_in_progress(link: product, preorder:)
    assert_equal false, preorder_charge.is_an_off_session_charge_on_indian_card?
  end

  test "#is_an_off_session_charge_on_indian_card? when card country is India returns false if it is a regular purchase" do
    assert_equal false, create_purchase_in_progress(link: create_product, card_country: "IN").is_an_off_session_charge_on_indian_card?
  end

  test "#is_an_off_session_charge_on_indian_card? when card country is India returns false if it is a membership purchase" do
    membership_purchase = create_purchase_in_progress(card_country: "IN", link: create_membership_product)
    assert_equal false, membership_purchase.is_an_off_session_charge_on_indian_card?
  end

  test "#is_an_off_session_charge_on_indian_card? when card country is India returns false if it is a recurring charge and charge processor is not Stripe" do
    product = create_subscription_product
    subscription = create_subscription(link: product)
    create_purchase(subscription:, is_original_subscription_purchase: true)
    recurring_charge = create_purchase_in_progress(is_original_subscription_purchase: false, link: product, card_country: "IN",
                                                   subscription:, charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                                   card_type: CardType::PAYPAL, card_visual: "jane@paypal.com")
    assert_equal false, recurring_charge.is_an_off_session_charge_on_indian_card?
  end

  test "#is_an_off_session_charge_on_indian_card? when card country is India returns false if it is a preorder charge but charge processor is not Stripe" do
    product = create_product(is_in_preorder_state: true)
    preorder_link = create_preorder_link(link: product)
    authorization_purchase = create_preorder_authorization_purchase(link: product)
    preorder = preorder_link.build_preorder(authorization_purchase)

    preorder_charge = create_purchase_in_progress(link: product, preorder:, card_country: "IN",
                                                  charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                                  card_type: CardType::PAYPAL, card_visual: "jane@paypal.com")
    assert_equal false, preorder_charge.is_an_off_session_charge_on_indian_card?
  end

  test "#is_an_off_session_charge_on_indian_card? when card country is India returns true if it is a recurring charge" do
    product = create_subscription_product
    subscription = create_subscription(link: product)
    create_purchase(subscription:, is_original_subscription_purchase: true)
    recurring_charge = create_purchase_in_progress(is_original_subscription_purchase: false, card_country: "IN", link: product, subscription:)
    assert_equal true, recurring_charge.is_an_off_session_charge_on_indian_card?
  end

  test "#is_an_off_session_charge_on_indian_card? when card country is India returns true if it is a preorder charge" do
    product = create_product(is_in_preorder_state: true)
    preorder_link = create_preorder_link(link: product)
    authorization_purchase = create_preorder_authorization_purchase(link: product)
    preorder = preorder_link.build_preorder(authorization_purchase)

    preorder_charge = create_purchase_in_progress(link: product, preorder:, card_country: "IN")
    assert_equal true, preorder_charge.is_an_off_session_charge_on_indian_card?
  end

  # ---- #can_force_update? ---------------------------------------------------

  test "#can_force_update? returns true if purchase is in progress and is not an off session charge on Indian card" do
    assert_equal true, create_purchase_in_progress(link: create_product).can_force_update?
  end

  test "#can_force_update? returns false if purchase is not in progress" do
    assert_equal false, create_purchase(purchase_state: "successful").can_force_update?
    assert_equal false, create_purchase(purchase_state: "failed").can_force_update?
  end

  test "#can_force_update? returns true if an off session charge on Indian card is in progress and was not created in the last 26 hours" do
    Purchase.any_instance.stubs(:is_an_off_session_charge_on_indian_card?).returns(true)
    assert_equal true, create_purchase_in_progress(link: create_product, created_at: 27.hours.ago).can_force_update?
  end

  test "#can_force_update? returns false if an off session charge on Indian card is in progress and was created in the last 26 hours" do
    Purchase.any_instance.stubs(:is_an_off_session_charge_on_indian_card?).returns(true)
    assert_equal false, create_purchase_in_progress(link: create_product, created_at: 10.hours.ago).can_force_update?
  end

  test "#can_force_update? returns false if an off session charge on Indian card is not in progress" do
    Purchase.any_instance.stubs(:is_an_off_session_charge_on_indian_card?).returns(true)
    assert_equal false, create_purchase(purchase_state: "failed", created_at: 27.hours.ago).can_force_update?
  end

  # ---- #confirm_charge_intent! ----------------------------------------------

  test "#confirm_charge_intent! asks the buyer to re-quote when Stripe invalidates the locked FX quote at confirmation" do
    purchase = create_purchase_in_progress(link: create_product)
    purchase.create_processor_payment_intent!(intent_id: "pi_test")
    ChargeProcessor.stubs(:confirm_payment_intent!).raises(ChargeProcessorFxQuoteInvalidError)

    purchase.confirm_charge_intent!

    assert_equal PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID, purchase.error_code
    assert_includes purchase.errors[:base], Charge::CreateService::BUYER_CURRENCY_QUOTE_INVALID_MESSAGE
  end

  test "#confirm_charge_intent! defers presentment purchases when Stripe settlement data is missing after SCA" do
    seller = create_user
    merchant_account = create_merchant_account_stripe_connect(user: seller)
    purchase = create_purchase_in_progress(
      link: create_product(user: seller),
      seller:,
      merchant_account:,
      is_part_of_combined_charge: true
    )
    charge = create_charge(order: create_order, seller:, merchant_account:)
    charge.purchases << purchase
    create_charge_presentment(charge:)
    purchase.create_processor_payment_intent!(intent_id: "pi_test")

    processor_charge = BaseProcessorCharge.new
    processor_charge.charge_processor_id = StripeChargeProcessor.charge_processor_id
    processor_charge.id = "ch_presentment"
    processor_charge.refunded = false
    processor_charge.fee = 59
    processor_charge.fee_currency = Currency::USD
    processor_charge.card_fingerprint = "card_fp"
    charge_intent = mock("charge_intent")
    charge_intent.stubs(:succeeded?).returns(true)
    charge_intent.stubs(:charge).returns(processor_charge)
    ChargeProcessor.stubs(:confirm_payment_intent!).returns(charge_intent)

    purchase.confirm_charge_intent!

    assert_empty purchase.errors
    assert purchase.reload.in_progress?
    assert_equal "ch_presentment", purchase.stripe_transaction_id
    assert_equal true, purchase.pending_buyer_presentment_settlement?
  end

  # ---- #save_charge_data ----------------------------------------------------

  test "#save_charge_data saves all charge related info from the given charge on the purchase" do
    VCR.use_cassette("Purchase/_save_charge_data/saves_all_charge_related_info_from_the_given_charge_on_the_purchase") do
      stripe_charge = ChargeProcessor.get_charge(StripeChargeProcessor.charge_processor_id, "ch_2OTlIf9e1RjUNIyY1adIdtGp")

      purchase = create_purchase_in_progress(link: create_product, charge_processor_id: nil, stripe_transaction_id: nil,
                                             processor_fee_cents_currency: nil, stripe_fingerprint: nil, stripe_card_id: nil,
                                             card_expiry_month: nil, card_expiry_year: nil, flow_of_funds: nil)
      assert_nil purchase.charge_processor_id
      assert_nil purchase.stripe_refunded
      assert_nil purchase.stripe_transaction_id
      assert_nil purchase.processor_fee_cents
      assert_nil purchase.processor_fee_cents_currency
      assert_nil purchase.stripe_fingerprint
      assert_nil purchase.stripe_card_id
      assert_nil purchase.card_expiry_month
      assert_nil purchase.card_expiry_year
      assert_equal false, purchase.was_zipcode_check_performed
      assert_nil purchase.flow_of_funds

      purchase.save_charge_data(stripe_charge)

      assert_equal StripeChargeProcessor.charge_processor_id, purchase.charge_processor_id
      assert_equal true, purchase.stripe_refunded
      assert_equal stripe_charge.id, purchase.stripe_transaction_id
      assert_equal stripe_charge.fee, purchase.processor_fee_cents
      assert_equal stripe_charge.fee_currency, purchase.processor_fee_cents_currency
      assert_equal stripe_charge.card_fingerprint, purchase.stripe_fingerprint
      assert_equal stripe_charge.card_instance_id, purchase.stripe_card_id
      assert_equal stripe_charge.card_expiry_month, purchase.card_expiry_month
      assert_equal stripe_charge.card_expiry_year, purchase.card_expiry_year
      assert_equal !stripe_charge.zip_check_result.nil?, purchase.was_zipcode_check_performed
      assert purchase.flow_of_funds.present?
      assert_equal stripe_charge.flow_of_funds, purchase.flow_of_funds
    end
  end

  test "#save_charge_data calls update_charge_details_from_processor! on the assoiated charge" do
    VCR.use_cassette("Purchase/_save_charge_data/calls_update_charge_details_from_processor_on_the_assoiated_charge") do
      stripe_charge = ChargeProcessor.get_charge(StripeChargeProcessor.charge_processor_id, "ch_2OTlIf9e1RjUNIyY1adIdtGp")

      charge = create_charge
      purchase = create_purchase
      charge.purchases << purchase

      # save_charge_data propagates the charge details to the associated Charge via
      # update_charge_details_from_processor!; asserting the persisted Charge fields below
      # proves that call ran with the processor charge's data.
      purchase.save_charge_data(stripe_charge)

      assert_equal StripeChargeProcessor.charge_processor_id, charge.reload.processor
      assert_equal stripe_charge.id, charge.processor_transaction_id
      assert_equal stripe_charge.fee, charge.processor_fee_cents
      assert_equal stripe_charge.fee_currency, charge.processor_fee_currency
      assert_equal stripe_charge.card_fingerprint, charge.payment_method_fingerprint
    end
  end

  test "#save_charge_data can save Stripe charge metadata without loading flow of funds" do
    stripe_charge = BaseProcessorCharge.new
    stripe_charge.charge_processor_id = StripeChargeProcessor.charge_processor_id
    stripe_charge.id = "ch_pending_settlement"
    stripe_charge.refunded = false
    stripe_charge.card_fingerprint = "card-fingerprint"
    stripe_charge.card_instance_id = "pm_card"
    stripe_charge.card_expiry_month = 12
    stripe_charge.card_expiry_year = 2030
    stripe_charge.flow_of_funds = nil

    charge = create_charge
    purchase = create_purchase_in_progress(
      link: create_product,
      charge_processor_id: nil,
      stripe_transaction_id: nil,
      processor_fee_cents_currency: nil,
      stripe_fingerprint: nil,
      stripe_card_id: nil,
      card_expiry_month: nil,
      card_expiry_year: nil,
      flow_of_funds: nil
    )
    charge.purchases << purchase

    assert_equal false, purchase.save_charge_data(stripe_charge, allow_missing_flow_of_funds: true)

    assert_equal StripeChargeProcessor.charge_processor_id, purchase.charge_processor_id
    assert_equal "ch_pending_settlement", purchase.stripe_transaction_id
    assert_equal "card-fingerprint", purchase.stripe_fingerprint
    assert_equal "pm_card", purchase.stripe_card_id
    assert_nil purchase.flow_of_funds
    assert_equal "ch_pending_settlement", charge.reload.processor_transaction_id
  end

  test "#save_charge_data Indian card e-mandate registration check reports an original subscription purchase whose charge carries no mandate" do
    purchase = build_india_mandate_charge_purchase(is_original_subscription_purchase: true)

    ErrorNotifier.expects(:notify).with(
      "Indian card recurring purchase completed without a registered e-mandate — its renewals will be declined by the issuer",
      purchase: purchase.external_id,
      stripe_charge: "ch_india_registration"
    )

    purchase.save_charge_data(build_india_mandate_processor_charge(mandate: nil))
  end

  test "#save_charge_data Indian card e-mandate registration check does not report when the charge carries a mandate" do
    purchase = build_india_mandate_charge_purchase(is_original_subscription_purchase: true)

    ErrorNotifier.expects(:notify).never

    purchase.save_charge_data(build_india_mandate_processor_charge(mandate: "mandate_123"))
  end

  test "#save_charge_data Indian card e-mandate registration check does not report recurring renewal charges (only the registering purchase carries a mandate)" do
    purchase = build_india_mandate_charge_purchase(is_original_subscription_purchase: false)

    ErrorNotifier.expects(:notify).never

    purchase.save_charge_data(build_india_mandate_processor_charge(mandate: nil))
  end

  test "#save_charge_data Indian card e-mandate registration check does not report non-Indian cards" do
    non_indian_card = build_india_mandate_credit_card(card_country: "US")
    purchase = build_india_mandate_charge_purchase(is_original_subscription_purchase: true, card: non_indian_card, card_country: "US")

    ErrorNotifier.expects(:notify).never

    purchase.save_charge_data(build_india_mandate_processor_charge(mandate: nil))
  end

  # ---- #check_indian_card_setup_intent_mandate_was_registered ---------------

  test "#check_indian_card_setup_intent_mandate_was_registered reports a succeeded setup intent that carries no mandate" do
    purchase = build_india_mandate_setup_intent_purchase
    stub_india_mandate_setup_intent(succeeded: true, mandate: nil)

    ErrorNotifier.expects(:notify).with(
      "Indian card recurring purchase completed without a registered e-mandate — its renewals will be declined by the issuer",
      purchase: purchase.external_id,
      stripe_setup_intent: "seti_india_registration"
    )

    purchase.check_indian_card_setup_intent_mandate_was_registered
  end

  test "#check_indian_card_setup_intent_mandate_was_registered does not report when the setup intent carries a mandate" do
    purchase = build_india_mandate_setup_intent_purchase
    stub_india_mandate_setup_intent(succeeded: true, mandate: "mandate_123")

    ErrorNotifier.expects(:notify).never

    purchase.check_indian_card_setup_intent_mandate_was_registered
  end

  test "#check_indian_card_setup_intent_mandate_was_registered does not report when the setup intent has not succeeded" do
    purchase = build_india_mandate_setup_intent_purchase
    stub_india_mandate_setup_intent(succeeded: false, mandate: nil)

    ErrorNotifier.expects(:notify).never

    purchase.check_indian_card_setup_intent_mandate_was_registered
  end

  test "#check_indian_card_setup_intent_mandate_was_registered does not report purchases without a setup intent" do
    purchase = build_india_mandate_setup_intent_purchase(setup_intent_id: nil)

    ChargeProcessor.expects(:get_setup_intent).never
    ErrorNotifier.expects(:notify).never

    purchase.check_indian_card_setup_intent_mandate_was_registered
  end

  test "#check_indian_card_setup_intent_mandate_was_registered does not report non-Indian cards" do
    purchase = build_india_mandate_setup_intent_purchase(card_country: "US")

    ChargeProcessor.expects(:get_setup_intent).never
    ErrorNotifier.expects(:notify).never

    purchase.check_indian_card_setup_intent_mandate_was_registered
  end

  test "#check_indian_card_setup_intent_mandate_was_registered never lets an unexpected error escape (observability only)" do
    purchase = build_india_mandate_setup_intent_purchase
    ChargeProcessor.stubs(:get_setup_intent).raises(StandardError, "boom")

    ErrorNotifier.expects(:notify).with(instance_of(StandardError), purchase: purchase.external_id)

    assert_nothing_raised { purchase.check_indian_card_setup_intent_mandate_was_registered }
  end

  # ---- #refunded? -----------------------------------------------------------

  test "#refunded? returns false when stripe_refunded is nil or false" do
    purchase = create_purchase(stripe_refunded: nil)
    assert_equal false, purchase.refunded?
    purchase.update!(stripe_refunded: false)
    assert_equal false, purchase.refunded?
  end

  test "#refunded? returns true when stripe_refunded is true" do
    purchase = create_purchase(stripe_refunded: true)
    assert_equal true, purchase.refunded?
  end

  # ---- #chargedback? --------------------------------------------------------

  test "#chargedback? returns false when chargeback_date is nil" do
    purchase = create_purchase(chargeback_date: nil)
    assert_equal false, purchase.chargedback?
  end

  test "#chargedback? returns true when chargeback_date is not nil" do
    purchase = create_purchase(chargeback_date: Time.current)
    assert_equal true, purchase.chargedback?
  end

  # ---- #chargedback_not_reversed? -------------------------------------------

  test "#chargedback_not_reversed? returns true when chargedback" do
    VCR.use_cassette("Purchase/_chargedback_not_reversed_/returns_true_when_chargedback") do
      purchase = create_disputed_purchase
      assert_equal true, purchase.chargedback_not_reversed?
    end
  end

  test "#chargedback_not_reversed? returns false when not chargedback" do
    purchase = create_purchase
    assert_equal false, purchase.chargedback_not_reversed?
  end

  test "#chargedback_not_reversed? returns false when chargedback and reversed" do
    VCR.use_cassette("Purchase/_chargedback_not_reversed_/returns_false_when_chargedback_and_reversed") do
      purchase = create_disputed_purchase(chargeback_reversed: true)
      assert_equal false, purchase.chargedback_not_reversed?
    end
  end

  # ---- #chargedback_not_reversed_or_refunded? -------------------------------

  test "#chargedback_not_reversed_or_refunded? returns true when chargedback" do
    VCR.use_cassette("Purchase/_chargedback_not_reversed_or_refunded_/returns_true_when_chargedback") do
      purchase = create_disputed_purchase
      assert_equal true, purchase.chargedback_not_reversed_or_refunded?
    end
  end

  test "#chargedback_not_reversed_or_refunded? returns false when not chargedback" do
    purchase = create_purchase
    assert_equal false, purchase.chargedback_not_reversed_or_refunded?
  end

  test "#chargedback_not_reversed_or_refunded? returns false when chargedback and reversed" do
    VCR.use_cassette("Purchase/_chargedback_not_reversed_or_refunded_/returns_false_when_chargedback_and_reversed") do
      purchase = create_disputed_purchase(chargeback_reversed: true)
      assert_equal false, purchase.chargedback_not_reversed_or_refunded?
    end
  end

  test "#chargedback_not_reversed_or_refunded? returns false when refunded" do
    purchase = create_refunded_purchase
    assert_equal true, purchase.chargedback_not_reversed_or_refunded?
  end

  # ---- #amount_refundable_cents ---------------------------------------------

  test "#amount_refundable_cents returns the refundable amount" do
    purchase = create_purchase(link: create_product(price_currency_type: Currency::EUR), price_cents: 200)
    assert_equal 200, purchase.amount_refundable_cents
  end

  test "#amount_refundable_cents for a purchase with a removed charge processor returns zero" do
    purchase = create_purchase(price_cents: 100)
    purchase.update!(charge_processor_id: "app_store")
    assert_equal 0, purchase.amount_refundable_cents
  end

  # ---- #non_refunded_total_transaction_amount -------------------------------

  test "#non_refunded_total_transaction_amount returns the full transaction amount when nothing has been refunded" do
    purchase = create_purchase(price_cents: 24_00)
    assert_equal 24_00, purchase.non_refunded_total_transaction_amount
  end

  test "#non_refunded_total_transaction_amount returns zero when the purchase is fully refunded" do
    purchase = create_purchase(price_cents: 24_00)
    create_refund(purchase:, amount_cents: purchase.price_cents, gumroad_tax_cents: 0)
    assert_equal 0, purchase.reload.non_refunded_total_transaction_amount
  end

  test "#non_refunded_total_transaction_amount subtracts a partial refund of the principal" do
    purchase = create_purchase(price_cents: 24_00)
    create_refund(purchase:, amount_cents: 10_00, gumroad_tax_cents: 0)
    assert_equal 14_00, purchase.reload.non_refunded_total_transaction_amount
  end

  test "#non_refunded_total_transaction_amount when Gumroad-collected tax was charged and refunded subtracts only the refunded tax when just the tax was refunded" do
    purchase = create_purchase(price_cents: 24_00, gumroad_tax_cents: 4_00, total_transaction_cents: 28_00)
    create_refund(purchase:, amount_cents: 0, gumroad_tax_cents: 4_00)
    assert_equal 24_00, purchase.reload.non_refunded_total_transaction_amount
  end

  test "#non_refunded_total_transaction_amount when Gumroad-collected tax was charged and refunded returns zero when both the principal and the tax were refunded" do
    purchase = create_purchase(price_cents: 24_00, gumroad_tax_cents: 4_00, total_transaction_cents: 28_00)
    create_refund(purchase:, amount_cents: 24_00, gumroad_tax_cents: 4_00)
    assert_equal 0, purchase.reload.non_refunded_total_transaction_amount
  end

  # ---- #amount_refundable_cents_in_currency ---------------------------------

  test "#amount_refundable_cents_in_currency returns the refundable amount in the purchase's currency" do
    purchase = create_purchase(link: create_product(price_currency_type: Currency::EUR), price_cents: 200)
    Purchase.any_instance.stubs(:get_rate).with(:eur).returns(0.8)
    purchase.update_columns(displayed_price_currency_type: "eur")
    assert_equal 160, purchase.amount_refundable_cents_in_currency
  end

  test "#amount_refundable_cents_in_currency when the product has been deleted uses displayed_price_currency_type from the purchase record" do
    purchase = create_purchase(link: create_product(price_currency_type: Currency::EUR), price_cents: 200)
    Purchase.any_instance.stubs(:get_rate).with(:eur).returns(0.8)
    purchase.update_columns(displayed_price_currency_type: "eur")
    purchase.link.destroy!
    assert_equal 160, purchase.reload.amount_refundable_cents_in_currency
  end

  # ---- #shipping_information ------------------------------------------------

  test "#shipping_information returns the shipping information" do
    purchase = create_shipping_purchase
    assert_equal(
      {
        full_name: "Full Name",
        street_address: "123 Gum Rd",
        city: "New York",
        state: "NY",
        zip_code: "10025",
        country: "United States",
      },
      purchase.shipping_information
    )
  end

  test "#shipping_information require_shipping is false for the product returns an empty object" do
    purchase = create_shipping_purchase
    purchase.link.update!(require_shipping: false)
    assert_equal({}, purchase.shipping_information)
  end

  test "#shipping_information when a value is nil defaults to an empty string" do
    purchase = create_shipping_purchase
    purchase.update!(full_name: nil)
    assert_equal "", purchase.shipping_information[:full_name]
  end

  # ---- #name_or_email -------------------------------------------------------

  test "#name_or_email full name is nil returns the email" do
    purchase = create_purchase
    assert_equal purchase.email, purchase.name_or_email
  end

  test "#name_or_email full name is empty returns the email" do
    purchase = create_purchase
    purchase.update!(full_name: "")
    assert_equal purchase.email, purchase.name_or_email
  end

  test "#name_or_email full name is present returns the full name" do
    purchase = create_purchase
    purchase.update!(full_name: "Crabcake Sam")
    assert_equal "Crabcake Sam", purchase.name_or_email
  end

  # ---- #prepare_for_charge! -------------------------------------------------

  test "#prepare_for_charge! in a country with taxes calculates taxes" do
    VCR.use_cassette("Purchase/_prepare_for_charge_/in_a_country_with_taxes/calculates_taxes") do
      create_zip_tax_rate(zip_code: nil, state: nil, country: Compliance::Countries::FRA.alpha2, combined_rate: 0.2, is_seller_responsible: false)
      purchase = build_purchase(chargeable: build_chargeable, country: "France", ip_country: "France")

      purchase.prepare_for_charge!

      assert_equal 20, purchase.gumroad_tax_cents
    end
  end

  test "#prepare_for_charge! in a country with taxes does not apply taxes if merchant account is a Brazilian Stripe Connect account" do
    VCR.use_cassette("Purchase/_prepare_for_charge_/in_a_country_with_taxes/does_not_apply_taxes_if_merchant_account_is_a_Brazilian_Stripe_Connect_account") do
      create_zip_tax_rate(zip_code: nil, state: nil, country: Compliance::Countries::FRA.alpha2, combined_rate: 0.2, is_seller_responsible: false)
      purchase = build_purchase(chargeable: build_chargeable, country: "France", ip_country: "France")

      purchase.seller.check_merchant_account_is_linked = true
      purchase.merchant_account = create_merchant_account_stripe_connect(user: purchase.seller, country: "BR")

      purchase.prepare_for_charge!

      assert_equal 0, purchase.gumroad_tax_cents
      assert_equal 0, purchase.tax_cents
    end
  end

  # ---- #commission ----------------------------------------------------------

  test "#commission returns the commission for the deposit and completion purchases" do
    VCR.use_cassette("Purchase/_commission/returns_the_commission_for_the_deposit_and_completion_purchases") do
      commission = create_commission
      commission.update!(completion_purchase: create_purchase(link: commission.deposit_purchase.link, is_commission_completion_purchase: true))

      assert_equal commission, commission.completion_purchase.commission
      assert_equal commission, commission.deposit_purchase.commission
    end
  end

  test "#commission when the purchase has no associated commission returns nil" do
    VCR.use_cassette("Purchase/_commission/when_the_purchase_has_no_associated_commission/returns_nil") do
      commission = create_commission
      commission.update!(completion_purchase: create_purchase(link: commission.deposit_purchase.link, is_commission_completion_purchase: true))

      purchase = create_purchase
      assert_nil purchase.commission
    end
  end

  # ---- #eligible_for_review_reminder? ---------------------------------------

  test "#eligible_for_review_reminder? returns true when all conditions are met" do
    purchase = create_purchase(purchaser: create_user, link: create_product(price_cents: 10_00))
    assert_equal true, purchase.eligible_for_review_reminder?
  end

  test "#eligible_for_review_reminder? when purchaser has opted out of review reminders returns false" do
    purchaser = create_user
    purchase = create_purchase(purchaser:, link: create_product(price_cents: 10_00))
    purchase.purchaser.stubs(:opted_out_of_review_reminders?).returns(true)
    assert_equal false, purchase.eligible_for_review_reminder?
  end

  test "#eligible_for_review_reminder? when purchase is subscription original subscription purchase returns true" do
    purchase = create_membership_purchase
    assert_equal true, purchase.eligible_for_review_reminder?
  end

  test "#eligible_for_review_reminder? when purchase is subscription recurring subscription purchase returns false" do
    original_purchase = create_membership_purchase
    purchase = create_membership_purchase(purchase_state: "successful", is_original_subscription_purchase: false, subscription: original_purchase.subscription)
    assert_equal false, purchase.eligible_for_review_reminder?
  end

  test "#eligible_for_review_reminder? when purchase is a bundle purchase returns false" do
    purchase = create_purchase(purchaser: create_user, link: create_product(price_cents: 10_00))
    purchase.update!(is_bundle_purchase: true)
    assert_equal false, purchase.eligible_for_review_reminder?
  end

  test "#eligible_for_review_reminder? when product review exists returns false" do
    purchase = create_purchase(purchaser: create_user, link: create_product(price_cents: 10_00))
    purchase.create_product_review
    assert_equal false, purchase.eligible_for_review_reminder?
  end

  test "#eligible_for_review_reminder? when purchase is not successful returns false" do
    purchase = create_purchase(purchaser: create_user, link: create_product(price_cents: 10_00))
    purchase.update!(purchase_state: "in_progress")
    assert_equal false, purchase.eligible_for_review_reminder?
  end

  test "#eligible_for_review_reminder? when purchase is refunded returns false" do
    purchase = create_purchase(purchaser: create_user, link: create_product(price_cents: 10_00))
    purchase.update!(stripe_refunded: true)
    assert_equal false, purchase.eligible_for_review_reminder?
  end

  test "#eligible_for_review_reminder? when purchaser is nil returns true" do
    purchase = create_purchase(purchaser: create_user, link: create_product(price_cents: 10_00))
    purchase.update!(purchaser: nil)
    assert_equal true, purchase.eligible_for_review_reminder?
  end

  test "#eligible_for_review_reminder? when the seller has disabled review reminders returns false" do
    purchase = create_purchase(purchaser: create_user, link: create_product(price_cents: 10_00))
    purchase.seller.update!(disable_review_reminders: true)
    assert_equal false, purchase.eligible_for_review_reminder?
  end

  # ---- #schedule_order_review_reminder --------------------------------------

  test "#schedule_order_review_reminder schedules the order review reminder when a purchase transitions to successful" do
    product = create_product(price_cents: 10_00)
    purchase = create_purchase_in_progress(link: product)
    order = create_order(purchases: [purchase])
    order.cart = create_cart(order:)

    assert_nil order.reload.review_reminder_scheduled_at
    purchase.mark_successful!
    assert_not_nil order.reload.review_reminder_scheduled_at
    assert_equal 1, OrderReviewReminderJob.jobs.size
  end

  test "#schedule_order_review_reminder does not schedule a reminder when the purchase fails" do
    product = create_product(price_cents: 10_00)
    purchase = create_purchase_in_progress(link: product)
    order = create_order(purchases: [purchase])
    order.cart = create_cart(order:)

    purchase.mark_failed!

    assert_nil order.reload.review_reminder_scheduled_at
    assert_empty OrderReviewReminderJob.jobs
  end

  test "#schedule_order_review_reminder does nothing when the purchase has no order" do
    product = create_product(price_cents: 10_00)
    purchase = create_purchase_in_progress(link: product)

    assert_nothing_raised { purchase.mark_successful! }
    assert_empty OrderReviewReminderJob.jobs
  end

  # ---- #license -------------------------------------------------------------

  test "#license when the purchase is a gifted subscription returns the license of the gifted purchase" do
    product = create_membership_product
    subscription = create_subscription(link: product)
    original_purchase = create_purchase(link: product, subscription:, is_original_subscription_purchase: true)
    gifted_purchase = create_purchase(subscription:, is_gift_receiver_purchase: true)
    create_license(purchase: original_purchase)

    gifted_license = create_license(purchase: gifted_purchase)
    assert_equal gifted_license, gifted_purchase.license
  end

  test "#license when the purchase is not a gifted subscription returns the license of the original purchase" do
    product = create_membership_product
    subscription = create_subscription(link: product)
    original_purchase = create_purchase(link: product, subscription:, is_original_subscription_purchase: true)
    purchase = create_purchase(subscription:)

    license = create_license(purchase: original_purchase)
    assert_equal license, purchase.license
  end

  # ---- #formatted_total_display_price_per_unit ------------------------------

  test "#formatted_total_display_price_per_unit normal purchase returns the formatted total display price per unit" do
    purchase = create_purchase
    assert_equal "$1", purchase.formatted_total_display_price_per_unit
  end

  test "#formatted_total_display_price_per_unit commission deposit purchase returns the formatted total display price" do
    VCR.use_cassette("Purchase/_formatted_total_display_price_per_unit/commission_deposit_purchase/returns_the_formatted_total_display_price") do
      purchase = create_commission_deposit_purchase
      purchase.create_artifacts_and_send_receipt!
      assert_equal "$2", purchase.reload.formatted_total_display_price_per_unit
    end
  end

  test "#formatted_total_display_price_per_unit with a tip returns the formatted total display price less the tip" do
    purchase = create_purchase(price_cents: 1000)
    purchase.create_tip!(value_cents: 500)
    assert_equal "$5", purchase.formatted_total_display_price_per_unit
  end

  test "#formatted_total_display_price_per_unit membership purchase returns the price with the recurring label" do
    purchase = create_membership_purchase(price_cents: 300)
    assert_equal "$3 a month", purchase.formatted_total_display_price_per_unit
  end

  test "#formatted_total_display_price_per_unit membership purchase when the membership only ever charges once renders one-time wording instead of a recurring label" do
    purchase = create_membership_purchase(price_cents: 300)
    purchase.subscription.update!(charge_occurrence_count: 1)
    assert_equal "$3 once", purchase.formatted_total_display_price_per_unit
  end

  # ---- #call ----------------------------------------------------------------

  test "#call when purchasing a call validates presence of call" do
    purchase = build_call_purchase
    purchase.call = nil
    assert_not purchase.valid?
    assert_includes purchase.errors[:call], "can't be blank"
  end

  test "#call when purchasing a call marks the purchase as invalid if the call is not valid" do
    purchase = build_call_purchase(call: build_call(start_time: 1.day.ago))

    assert_not purchase.valid?
    assert_includes purchase.errors.full_messages, "Call Selected time is no longer available"
  end

  test "#call when not purchasing a call does not validate presence of call" do
    purchase = build_physical_purchase
    purchase.call = nil
    purchase.valid?
    assert_not_includes purchase.errors[:call], "can't be blank"
  end

  # ---- #determine_affiliate_fee_cents ---------------------------------------

  test "#determine_affiliate_fee_cents returns affiliate's share of the fee" do
    VCR.use_cassette("Purchase/_determine_affiliate_fee_cents/returns_affiliate_s_share_of_the_fee") do
      product = create_product(price_cents: 10_00)
      affiliate = create_direct_affiliate(affiliate_basis_points: 7500, products: [product])
      affiliate_purchase = create_purchase(link: product, seller: product.user, affiliate:, save_card: false, ip_address: "24.7.90.214", chargeable: build_chargeable)

      assert_equal 156.75, affiliate_purchase.send(:determine_affiliate_fee_cents)
      assert_equal affiliate_purchase.fee_cents * 0.75, affiliate_purchase.send(:determine_affiliate_fee_cents)
    end
  end

  test "#determine_affiliate_fee_cents returns 0 if seller bears affiliate fees" do
    VCR.use_cassette("Purchase/_determine_affiliate_fee_cents/returns_0_if_seller_bears_affiliate_fees") do
      product = create_product(price_cents: 10_00)
      affiliate = create_direct_affiliate(affiliate_basis_points: 7500, products: [product])
      product.user.update!(bears_affiliate_fee: true)
      affiliate_purchase = create_purchase(link: product, seller: product.user, affiliate:, save_card: false, ip_address: "24.7.90.214", chargeable: build_chargeable)

      assert_equal 0, affiliate_purchase.send(:determine_affiliate_fee_cents)
      assert_equal 209, affiliate_purchase.fee_cents
    end
  end

  # ---- #determine_affiliate_balance_cents -----------------------------------

  test "#determine_affiliate_balance_cents returns 0 when the affiliate user is the seller (self-affiliate)" do
    seller = create_user
    product = create_product(user: seller, price_cents: 10_00)
    global_affiliate = seller.global_affiliate
    assert_equal seller.id, global_affiliate.affiliate_user_id

    purchase = create_purchase(link: product, seller:, affiliate: global_affiliate)

    assert_equal 0, purchase.send(:determine_affiliate_balance_cents)
    assert_equal 0, purchase.affiliate_credit_cents
  end

  test "#determine_affiliate_balance_cents credits the affiliate normally when the affiliate user is not the seller" do
    seller = create_user
    product = create_product(user: seller, price_cents: 10_00)
    affiliate_user = create_user
    direct_affiliate = create_direct_affiliate(seller:, affiliate_user:, affiliate_basis_points: 1000, products: [product])

    purchase = create_purchase(link: product, seller:, affiliate: direct_affiliate)

    assert_operator purchase.send(:determine_affiliate_balance_cents), :>, 0
    assert_operator purchase.affiliate_credit_cents, :>, 0
  end

  # ---- #gift_purchases_cannot_be_on_installment_plans -----------------------

  test "#gift_purchases_cannot_be_on_installment_plans does not allow gift purchases to be on installment plans" do
    purchase = create_purchase(is_installment_payment: true, installment_plan: create_product_installment_plan)

    purchase.is_gift_receiver_purchase = true
    purchase.is_gift_sender_purchase = false
    assert_not purchase.valid?
    assert_includes purchase.errors.full_messages, "Gift purchases cannot be on installment plans."

    purchase.is_gift_receiver_purchase = true
    purchase.is_gift_sender_purchase = false
    assert_not purchase.valid?
    assert_includes purchase.errors.full_messages, "Gift purchases cannot be on installment plans."

    purchase.is_gift_receiver_purchase = false
    purchase.is_gift_sender_purchase = false
    purchase.validate
    assert_not_includes purchase.errors.full_messages, "Gift purchases cannot be on installment plans."
  end

  # ---- within_refund_policy_timeframe? --------------------------------------

  test "within_refund_policy_timeframe? when purchase is not successful or gift receiver purchase was not successful or not in not_charged state returns false" do
    purchase, _refund_policy = build_refund_policy_purchase
    purchase.stubs(:successful?).returns(false)
    purchase.stubs(:gift_receiver_purchase_successful?).returns(false)
    purchase.stubs(:not_charged?).returns(false)

    assert_equal false, purchase.within_refund_policy_timeframe?
  end

  test "within_refund_policy_timeframe? when purchase is refunded or chargedback returns false" do
    purchase, _refund_policy = build_refund_policy_purchase
    purchase.stubs(:successful?).returns(true)
    purchase.stubs(:refunded?).returns(true)

    assert_equal false, purchase.within_refund_policy_timeframe?

    purchase.stubs(:refunded?).returns(false)
    purchase.stubs(:chargedback?).returns(true)

    assert_equal false, purchase.within_refund_policy_timeframe?
  end

  test "within_refund_policy_timeframe? when there is no refund policy returns false" do
    purchase, _refund_policy = build_refund_policy_purchase
    purchase.stubs(:successful?).returns(true)
    purchase.stubs(:refunded?).returns(false)
    purchase.stubs(:chargedback?).returns(false)
    purchase.stubs(:purchase_refund_policy).returns(nil)

    assert_equal false, purchase.within_refund_policy_timeframe?
  end

  test "within_refund_policy_timeframe? when refund policy max_refund_period_in_days is nil or <= 0 returns false" do
    purchase, refund_policy = build_refund_policy_purchase
    purchase.stubs(:successful?).returns(true)
    purchase.stubs(:refunded?).returns(false)
    purchase.stubs(:chargedback?).returns(false)

    refund_policy.max_refund_period_in_days = nil
    assert_equal false, purchase.within_refund_policy_timeframe?

    refund_policy.max_refund_period_in_days = 0
    assert_equal false, purchase.within_refund_policy_timeframe?

    refund_policy.max_refund_period_in_days = -1
    assert_equal false, purchase.within_refund_policy_timeframe?
  end

  test "within_refund_policy_timeframe? when the purchase is within the refund policy timeframe returns true" do
    purchase, refund_policy = build_refund_policy_purchase
    purchase.stubs(:successful?).returns(true)
    purchase.stubs(:refunded?).returns(false)
    purchase.stubs(:chargedback?).returns(false)
    refund_policy.max_refund_period_in_days = 30
    purchase.created_at = 15.days.ago

    assert_equal true, purchase.within_refund_policy_timeframe?
  end

  test "within_refund_policy_timeframe? when the purchase is outside the refund policy timeframe returns false" do
    purchase, refund_policy = build_refund_policy_purchase
    purchase.stubs(:successful?).returns(true)
    purchase.stubs(:refunded?).returns(false)
    purchase.stubs(:chargedback?).returns(false)
    refund_policy.max_refund_period_in_days = 30
    purchase.created_at = 31.days.ago

    assert_equal false, purchase.within_refund_policy_timeframe?
  end

  # ---- #calculate_custom_fee_per_thousand -----------------------------------

  test "#calculate_custom_fee_per_thousand does nothing and returns if custom fee is already set" do
    purchase = create_purchase(custom_fee_per_thousand: 50)
    assert_equal 50, purchase.custom_fee_per_thousand

    purchase.expects(:is_recurring_subscription_charge).never
    purchase.seller.expects(:custom_fee_per_thousand).never

    purchase.send(:calculate_custom_fee_per_thousand)
    assert_equal 50, purchase.custom_fee_per_thousand
  end

  test "#calculate_custom_fee_per_thousand does nothing and returns if discover fee is being charged" do
    seller = create_user
    product = create_product(user: seller)
    purchase = create_purchase(link: product)
    seller.update!(custom_fee_per_thousand: 50)
    Purchase.any_instance.stubs(:charge_discover_fee?).returns(true)

    purchase.expects(:is_recurring_subscription_charge).never
    purchase.seller.expects(:custom_fee_per_thousand).never

    purchase.send(:calculate_custom_fee_per_thousand)
    assert_nil purchase.custom_fee_per_thousand
  end

  test "#calculate_custom_fee_per_thousand for a recurring charge when original subscription purchase had a custom fee sets custom fee same as original subscription purchase's custom fee" do
    subscription = create_subscription
    original_subscription_purchase = create_purchase(subscription:, is_original_subscription_purchase: true)
    original_subscription_purchase.update!(custom_fee_per_thousand: 50)
    original_subscription_purchase.seller.update!(custom_fee_per_thousand: 75)

    recurring_purchase = create_purchase(subscription:, is_original_subscription_purchase: false)
    assert_nil recurring_purchase.reload.custom_fee_per_thousand

    recurring_purchase.send(:calculate_custom_fee_per_thousand)
    assert_equal 50, recurring_purchase.custom_fee_per_thousand
  end

  test "#calculate_custom_fee_per_thousand for a recurring charge when original subscription purchase did not have a custom fee but the seller has one set falls back to the seller's custom fee" do
    subscription = create_subscription
    original_subscription_purchase = create_purchase(subscription:, is_original_subscription_purchase: true)
    recurring_purchase = create_purchase(subscription:, is_original_subscription_purchase: false)
    recurring_purchase.seller.update!(custom_fee_per_thousand: 75)
    assert_nil original_subscription_purchase.custom_fee_per_thousand
    assert_nil recurring_purchase.reload.custom_fee_per_thousand

    recurring_purchase.send(:calculate_custom_fee_per_thousand)
    assert_equal 75, recurring_purchase.custom_fee_per_thousand
  end

  test "#calculate_custom_fee_per_thousand for a recurring charge when neither the original subscription purchase nor the seller has a custom fee does not set a custom fee" do
    subscription = create_subscription
    original_subscription_purchase = create_purchase(subscription:, is_original_subscription_purchase: true)
    assert_nil original_subscription_purchase.custom_fee_per_thousand
    assert_nil original_subscription_purchase.seller.custom_fee_per_thousand

    recurring_purchase = create_purchase(subscription:, is_original_subscription_purchase: false)
    assert_nil recurring_purchase.reload.custom_fee_per_thousand

    recurring_purchase.send(:calculate_custom_fee_per_thousand)
    assert_nil recurring_purchase.custom_fee_per_thousand
  end

  test "#calculate_custom_fee_per_thousand for a preorder charge when preorder authorization purchase had a custom fee sets custom fee same as preorder authorization purchase's custom fee" do
    VCR.use_cassette("Purchase/_calculate_custom_fee_per_thousand/for_a_preorder_charge/when_preorder_authorization_purchase_had_a_custom_fee/sets_custom_fee_same_as_preorder_authorization_purchase_s_custom_fee") do
      seller = create_user
      product = create_product(user: seller, price_cents: 10_00, is_in_preorder_state: true)
      preorder_product = create_preorder_link(link: product)
      authorization_purchase = build_purchase(link: product, chargeable: build_chargeable, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = preorder_product.build_preorder(authorization_purchase)

      authorization_purchase.update!(custom_fee_per_thousand: 50)
      authorization_purchase.seller.update!(custom_fee_per_thousand: 75)

      preorder.authorize!
      preorder.mark_authorization_successful
      product.update!(is_in_preorder_state: false)
      preorder_charge = preorder.reload.charge!

      assert_equal 50, preorder_charge.custom_fee_per_thousand
      assert_equal 1_59, preorder_charge.fee_cents # 5% gumroad flat fee + 50c + 2.9% cc fee + 30c fixed cc fee

      preorder_charge.send(:calculate_custom_fee_per_thousand)
      assert_equal 50, preorder_charge.custom_fee_per_thousand
    end
  end

  test "#calculate_custom_fee_per_thousand for a preorder charge when preorder authorization purchase did not have a custom fee does not set a custom fee" do
    VCR.use_cassette("Purchase/_calculate_custom_fee_per_thousand/for_a_preorder_charge/when_preorder_authorization_purchase_did_not_have_a_custom_fee/does_not_set_a_custom_fee") do
      seller = create_user
      product = create_product(user: seller, price_cents: 10_00, is_in_preorder_state: true)
      preorder_product = create_preorder_link(link: product)
      authorization_purchase = build_purchase(link: product, chargeable: build_chargeable, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = preorder_product.build_preorder(authorization_purchase)

      preorder.authorize!
      preorder.mark_authorization_successful
      product.update!(is_in_preorder_state: false)

      authorization_purchase.seller.update!(custom_fee_per_thousand: 75)
      preorder_charge = preorder.reload.charge!

      assert_nil preorder_charge.custom_fee_per_thousand
      assert_equal 2_09, preorder_charge.fee_cents # 10% gumroad flat fee + 50c + 2.9% cc fee + 30c fixed cc fee

      preorder_charge.send(:calculate_custom_fee_per_thousand)
      assert_nil preorder_charge.custom_fee_per_thousand
    end
  end

  test "#calculate_custom_fee_per_thousand for a regular purchase when seller has a custom fee set sets custom fee same as seller's custom fee" do
    seller = create_user
    product = create_product(user: seller)
    seller.update!(custom_fee_per_thousand: 50)
    purchase = create_purchase(link: product)
    assert_equal 50, purchase.custom_fee_per_thousand

    purchase.send(:calculate_custom_fee_per_thousand)
    assert_equal 50, purchase.custom_fee_per_thousand
  end

  test "#calculate_custom_fee_per_thousand for a regular purchase when seller does not have a custom fee set does not set a custom fee" do
    seller = create_user
    product = create_product(user: seller)
    purchase = create_purchase(link: product)
    assert_nil purchase.custom_fee_per_thousand

    purchase.send(:calculate_custom_fee_per_thousand)
    assert_nil purchase.custom_fee_per_thousand
  end

  test "#calculate_custom_fee_per_thousand for a new subscription purchase when seller has a custom fee set sets custom fee same as seller's custom fee" do
    seller = create_user
    membership_product = create_membership_product(user: seller)
    subscription = create_subscription(link: membership_product)
    subscription_purchase = create_purchase(subscription:, link: membership_product, is_original_subscription_purchase: true)
    assert_nil subscription_purchase.custom_fee_per_thousand

    seller.update!(custom_fee_per_thousand: 25)
    subscription_purchase.send(:calculate_custom_fee_per_thousand)
    assert_equal 25, subscription_purchase.custom_fee_per_thousand
  end

  test "#calculate_custom_fee_per_thousand for a new subscription purchase when seller does not have a custom fee set does not set a custom fee" do
    seller = create_user
    membership_product = create_membership_product(user: seller)
    subscription = create_subscription(link: membership_product)
    subscription_purchase = create_purchase(subscription:, link: membership_product, is_original_subscription_purchase: true)
    assert_nil subscription_purchase.custom_fee_per_thousand

    subscription_purchase.send(:calculate_custom_fee_per_thousand)
    assert_nil subscription_purchase.custom_fee_per_thousand
  end

  # ---- .validate_offer_code_usage_across_line_items -------------------------

  test ".validate_offer_code_usage_across_line_items fails every line item when the cart collectively exceeds max_purchase_count" do
    seller = create_user
    product = create_product(user: seller, price_cents: 1_000)
    offer_code = create_offer_code(products: [product], code: "once", amount_cents: 100, max_purchase_count: 1)
    purchases = [build_offer_code_line_item_purchase(product:, seller:, offer_code:), build_offer_code_line_item_purchase(product:, seller:, offer_code:)]

    Purchase.validate_offer_code_usage_across_line_items(purchases)

    purchases.each do |purchase|
      assert_equal "failed", purchase.reload.purchase_state
      assert_equal PurchaseErrorCode::EXCEEDING_OFFER_CODE_QUANTITY, purchase.error_code
      assert_match(/quantity you have selected/, purchase.errors[:base].first)
    end
  end

  test ".validate_offer_code_usage_across_line_items leaves line items alone when the cart fits within max_purchase_count" do
    seller = create_user
    product = create_product(user: seller, price_cents: 1_000)
    offer_code = create_offer_code(products: [product], code: "plenty", amount_cents: 100, max_purchase_count: 5)
    purchases = [build_offer_code_line_item_purchase(product:, seller:, offer_code:), build_offer_code_line_item_purchase(product:, seller:, offer_code:)]

    Purchase.validate_offer_code_usage_across_line_items(purchases)

    purchases.each do |purchase|
      assert_equal "in_progress", purchase.reload.purchase_state
      assert_nil purchase.error_code
    end
  end

  test ".validate_offer_code_usage_across_line_items skips single-line carts (already handled by per-purchase validation)" do
    seller = create_user
    product = create_product(user: seller, price_cents: 1_000)
    offer_code = create_offer_code(products: [product], code: "single", amount_cents: 100, max_purchase_count: 1)
    purchase = build_offer_code_line_item_purchase(product:, seller:, offer_code:)

    Purchase.validate_offer_code_usage_across_line_items([purchase])

    assert_equal "in_progress", purchase.reload.purchase_state
  end

  # ---- #auto_delete_single_use_offer_code -----------------------------------

  test "#auto_delete_single_use_offer_code auto-deletes a single-use offer code after a successful purchase" do
    user = create_user
    product = create_product(user:, price_cents: 1000)
    offer_code = create_offer_code(products: [product], max_purchase_count: 1)
    create_purchase(offer_code:, link: product, seller: user, price_cents: product.price_cents)

    assert offer_code.reload.deleted?
  end

  test "#auto_delete_single_use_offer_code does not auto-delete offer codes for non-successful purchases" do
    user = create_user
    product = create_product(user:, price_cents: 1000)
    offer_code = create_offer_code(products: [product], max_purchase_count: 1)
    create_failed_purchase(offer_code:, link: product, seller: user, price_cents: product.price_cents)

    assert_not offer_code.reload.deleted?
  end

  test "#auto_delete_single_use_offer_code does not auto-delete when the purchase has no offer code" do
    user = create_user
    product = create_product(user:, price_cents: 1000)
    purchase = create_purchase(link: product, seller: user, price_cents: product.price_cents)

    assert purchase.persisted?
  end

  test "#auto_delete_single_use_offer_code does not auto-delete multi-use offer codes" do
    user = create_user
    product = create_product(user:, price_cents: 1000)
    offer_code = create_offer_code(products: [product], max_purchase_count: 3)
    create_purchase(offer_code:, link: product, seller: user, price_cents: product.price_cents)

    assert_not offer_code.reload.deleted?
  end

  test "#auto_delete_single_use_offer_code does not break the purchase flow if auto-delete raises an error" do
    user = create_user
    product = create_product(user:, price_cents: 1000)
    offer_code = create_offer_code(products: [product], max_purchase_count: 1)
    OfferCode.any_instance.stubs(:auto_delete_if_single_use_exhausted!).raises(StandardError, "unexpected error")

    purchase = create_purchase(offer_code:, link: product, seller: user, price_cents: product.price_cents)

    assert purchase.persisted?
    assert_not offer_code.reload.deleted?
  end

  # ---- #attach_to_user_and_card ---------------------------------------------

  test "#attach_to_user_and_card attaches the purchase to the user" do
    user = create_user
    purchase = create_purchase

    purchase.attach_to_user_and_card(user, nil, nil)

    assert_equal user, purchase.reload.purchaser
  end

  test "#attach_to_user_and_card refuses to attach a reassignment-locked purchase" do
    user = create_user
    purchase = create_purchase(is_reassignment_locked: true)

    assert_equal false, purchase.attach_to_user_and_card(user, nil, nil)
    assert_nil purchase.reload.purchaser
  end

  test "#attach_to_user_and_card does not move a reassignment-locked purchase's subscription" do
    user = create_user
    purchase = create_membership_purchase(is_reassignment_locked: true)
    subscription = purchase.subscription
    original_subscriber = subscription.user

    purchase.attach_to_user_and_card(user, nil, nil)

    assert_equal original_subscriber, subscription.reload.user
  end

  private
    def ensure_gumroad_merchant_accounts
      # MerchantAccount.gumroad(processor) looks up `where(user_id: nil, ...)`, so the
      # platform accounts must have a nil user. The shared create_merchant_account*
      # builders coerce `user: nil` into a freshly-created user (`user || create_user`),
      # which would NOT be a Gumroad account — so build these rows directly.
      MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
        MerchantAccount.create!(user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                charge_processor_merchant_id: "acct_#{unique_suffix}", charge_processor_alive_at: Time.current)
      MerchantAccount.gumroad(PaypalChargeProcessor.charge_processor_id) ||
        MerchantAccount.create!(user: nil, charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                charge_processor_merchant_id: "paypal_#{unique_suffix}", charge_processor_alive_at: Time.current)
      MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id) ||
        MerchantAccount.create!(user: nil, charge_processor_id: BraintreeChargeProcessor.charge_processor_id,
                                charge_processor_merchant_id: "braintree_#{unique_suffix}", charge_processor_alive_at: Time.current)
    end

    def create_as_json_purchase
      create_purchase(chargeback_date: 1.minute.ago, full_name: "Sahil Lavingia", email: "sahil@gumroad.com")
    end

    def setup_tiered_membership_subscriptions
      user = create_user
      recurrence_price_values = [
        {
          BasePrice::Recurrence::MONTHLY => { enabled: true, price: 10 },
          BasePrice::Recurrence::YEARLY => { enabled: true, price: 100 }
        },
        {
          BasePrice::Recurrence::MONTHLY => { enabled: true, price: 2 },
          BasePrice::Recurrence::YEARLY => { enabled: true, price: 2 }
        }
      ]
      product = create_membership_product_with_preset_tiered_pricing(recurrence_price_values:)
      yearly_price = product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::YEARLY)
      monthly_subscription = create_subscription(user:, link: product)
      yearly_subscription = create_subscription(user:, link: product)
      payment_option = yearly_subscription.payment_options.first
      payment_option.price = yearly_price
      payment_option.save!
      yearly_subscription.reload
      [product, monthly_subscription, yearly_subscription]
    end

    def create_physical_purchase(**attrs)
      create_purchase(
        full_name: "barnabas",
        street_address: "123 barnabas street",
        city: "barnabasville",
        state: "CA",
        country: "United States",
        zip_code: "94114",
        **attrs
      )
    end

    def create_tip(purchase:, value_cents: 100, **attrs)
      Tip.create!({ purchase:, value_cents: }.merge(attrs))
    end

    def create_utm_link(seller: nil, **attrs)
      UtmLink.create!({
        seller: seller || create_user,
        title: "UTM Link #{unique_suffix}",
        target_resource_type: :profile_page,
        utm_campaign: "summer-sale-#{unique_suffix}",
        utm_medium: "social",
        utm_source: "twitter",
      }.merge(attrs))
    end

    def create_utm_link_visit(utm_link:, **attrs)
      UtmLinkVisit.create!({
        utm_link:,
        ip_address: "127.0.0.1",
        browser_guid: SecureRandom.uuid,
        country_code: "US",
        referrer: "https://twitter.com",
        user_agent: "Mozilla/5.0",
      }.merge(attrs))
    end

    def create_utm_link_driven_sale(utm_link:, purchase:, utm_link_visit: nil, **attrs)
      utm_link_visit ||= create_utm_link_visit(utm_link:)
      UtmLinkDrivenSale.create!({ utm_link:, utm_link_visit:, purchase: }.merge(attrs))
    end

    def create_order(purchases: nil, purchaser: nil)
      order = Order.create!(purchaser: purchaser || create_user)
      order.purchases = purchases if purchases
      order
    end

    def create_cart(order: nil, user: :default, **attrs)
      user = create_user if user == :default
      Cart.create!({ user:, browser_guid: SecureRandom.uuid, ip_address: unique_ip, order: }.merge(attrs))
    end

    def create_sent_abandoned_cart_email(cart:, installment:, **attrs)
      SentAbandonedCartEmail.create!({ cart:, installment: }.merge(attrs))
    end

    def create_preorder_link(link: nil, **attrs)
      PreorderLink.create!({ link: link || create_product, release_at: 2.months.from_now }.merge(attrs))
    end

    def create_preorder(preorder_link: nil, seller: nil, **attrs)
      preorder_link ||= create_preorder_link
      Preorder.create!({ preorder_link:, seller: seller || preorder_link.link.user, state: "in_progress" }.merge(attrs))
    end

    def create_oauth_application(owner: nil, **attrs)
      OauthApplication.create!({ name: "app-#{unique_suffix}", redirect_uri: "https://foo", owner: owner || create_user }.merge(attrs))
    end

    def create_resource_subscription(user:, resource_name: ResourceSubscription::SALE_RESOURCE_NAME, oauth_application: nil, **attrs)
      ResourceSubscription.create!({
        user:,
        oauth_application: oauth_application || create_oauth_application(owner: user),
        resource_name:,
        post_url: "http://example.com",
      }.merge(attrs))
    end

    def create_team_membership(user:, seller:, role: TeamMembership::ROLE_ADMIN, **attrs)
      user.create_owner_membership_if_needed!
      TeamMembership.create!({ user:, seller:, role: }.merge(attrs))
    end

    def create_upsell_purchase(**attrs)
      upsell = create_upsell(seller: create_user, cross_sell: true)
      purchase = create_purchase(link: upsell.product, offer_code: upsell.offer_code)
      UpsellPurchase.create!({ upsell:, selected_product: upsell.product, purchase: }.merge(attrs))
    end

    def assert_json_includes(expected, actual)
      expected.each do |key, value|
        assert actual.key?(key), "expected json to have key #{key.inspect}"
        assert_equal value, actual[key], "for key #{key.inspect}"
      end
    end

    def refute_json_keys(keys, actual)
      keys.each { |key| assert_not actual.key?(key), "expected json not to have key #{key.inspect}" }
    end

    def ip_address = "24.7.90.214"

    def setup_create_url_redirect_outer
      @purchase = create_purchase
      @purchase.perceived_price_cents = 100
      @purchase.save_card = false
      @purchase.ip_address = ip_address
      @purchase.chargeable = build_chargeable
      @purchase.process!
    end

    def setup_create_url_redirect_subscriptions
      setup_create_url_redirect_outer
      @user = create_user
      @product = create_membership_product(user: @user, price_cents: 600, subscription_duration: :monthly, should_include_last_post: true)
      @subscription = create_subscription(link: @product)
      @purchase = create_purchase(link: @product, seller: @user, purchase_state: "in_progress", is_original_subscription_purchase: true)
      @purchase.perceived_price_cents = 100
      @purchase.ip_address = ip_address
      @purchase.chargeable = build_chargeable
      @purchase.process!
      @post = create_installment(link: @product, published_at: 1.hour.ago)
      @post.product_files << create_product_file
      @workflow = create_workflow(seller: @user, link: @product, published_at: Time.current)
      @workflow_post = create_installment(link: @product, workflow: @workflow, published_at: Time.current)
      create_installment_rule(installment: @workflow_post, delayed_delivery_time: 3.days)
    end

    def setup_variant_extra_cost_tiered
      recurrence_price_values = [
        { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 10 }, BasePrice::Recurrence::YEARLY => { enabled: true, price: 100 } },
        { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 5 }, BasePrice::Recurrence::YEARLY => { enabled: true, price: 50 } }
      ]
      product = create_membership_product_with_preset_tiered_pricing(recurrence_price_values:)
      @yearly_price = product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::YEARLY)
      @tier = product.tiers.find_by!(name: "Second Tier")
      @purchase = create_purchase(link: product, variant_attributes: [@tier], price: @yearly_price)
    end

    def setup_gumroad_day_seller
      seller = create_named_seller
      $redis.set(RedisKey.gumroad_day_date, Time.now.in_time_zone(seller.timezone).to_date.to_s)
      seller
    end

    def setup_waive_feature_seller
      seller = create_named_seller
      Feature.activate_user(:waive_gumroad_fee_on_new_sales, seller)
      seller
    end

    def assert_waived_regular_product_sale(seller)
      purchase = create_purchase(link: create_product(user: seller), price_cents: 10_00)
      assert purchase.seller.waive_gumroad_fee_on_new_sales?
      assert_equal 109, purchase.fee_cents # 2.9% + 30c cc fee
    end

    def assert_waived_new_membership_sale(seller)
      purchase = create_membership_purchase_new_sale(link: create_membership_product(user: seller), price_cents: 10_00)
      assert purchase.seller.waive_gumroad_fee_on_new_sales?
      assert_equal 109, purchase.fee_cents # 2.9% + 30c cc fee
    end

    def assert_waived_recommended_regular_sale(seller)
      purchase = create_purchase(link: create_product(user: seller), price_cents: 10_00,
                                 was_product_recommended: true,
                                 recommended_by: RecommendationType::GUMROAD_SEARCH_RECOMMENDATION)
      assert purchase.seller.waive_gumroad_fee_on_new_sales?
      assert purchase.was_product_recommended?
      assert_equal 200, purchase.fee_cents # 30% discover fee - 10% Gumroad fee
    end

    def assert_waived_recommended_new_membership_sale(seller)
      purchase = create_membership_purchase_new_sale(link: create_membership_product(user: seller), price_cents: 10_00,
                                                     was_product_recommended: true,
                                                     recommended_by: RecommendationType::GUMROAD_SEARCH_RECOMMENDATION)
      assert purchase.seller.waive_gumroad_fee_on_new_sales?
      assert_equal 200, purchase.fee_cents # 30% discover fee - 10% Gumroad fee
    end

    def assert_boost_fee_minus_gumroad_recommended_new_membership(seller)
      purchase = create_membership_purchase_new_sale(
        link: create_membership_product(user: seller, discover_fee_per_thousand: 400),
        price_cents: 10_00,
        was_product_recommended: true,
        recommended_by: RecommendationType::GUMROAD_SEARCH_RECOMMENDATION)
      assert purchase.seller.waive_gumroad_fee_on_new_sales?
      assert purchase.was_product_recommended?
      assert purchase.was_discover_fee_charged?
      assert_equal 200, purchase.fee_cents # 30% discover fee - 10% gumroad fee
    end

    def assert_gumroad_fee_recurring_existing_membership(seller)
      membership_sale = create_membership_purchase(link: create_membership_product(user: seller),
                                                   created_at: 1.week.ago, price_cents: 10_00)
      recurring_charge = create_recurring_membership_purchase(link: membership_sale.link,
                                                              subscription: membership_sale.subscription, price_cents: 10_00)

      assert recurring_charge.seller.waive_gumroad_fee_on_new_sales?
      assert_equal 2_09, recurring_charge.fee_cents # 10% + 50c gumroad fee + 2.9% cc fee + 30c fixed cc fee
    end

    def assert_boost_fee_including_gumroad_recurring_recommended_membership(seller)
      membership_sale = create_membership_purchase(
        link: create_membership_product(user: seller, discover_fee_per_thousand: 400),
        created_at: 1.week.ago,
        price_cents: 10_00,
        was_product_recommended: true,
        recommended_by: RecommendationType::GUMROAD_SEARCH_RECOMMENDATION)
      membership_sale.handle_recommended_purchase
      Subscription.any_instance.stubs(:mor_fee_applicable?).returns(false)

      recurring_charge = create_recurring_membership_purchase(
        link: membership_sale.link,
        subscription: membership_sale.subscription,
        price_cents: 10_00,
        was_product_recommended: true,
        recommended_by: RecommendationType::GUMROAD_SEARCH_RECOMMENDATION)

      assert recurring_charge.seller.waive_gumroad_fee_on_new_sales?
      assert recurring_charge.was_product_recommended?
      assert recurring_charge.was_discover_fee_charged?
      assert_equal 459, recurring_charge.fee_cents # 30% (boost fee) + 12.9% + 30c cc fee
    end

    def assert_gumroad_fee_existing_preorder(seller)
      product = create_product(user: seller, price_cents: 10_00, is_in_preorder_state: true)
      preorder_product = create_preorder_link(link: product)
      authorization_purchase = build_purchase(link: product, chargeable: build_chargeable,
                                              purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful
      product.update!(is_in_preorder_state: false)
      preorder_charge = preorder.charge!

      assert preorder_charge.seller.waive_gumroad_fee_on_new_sales?
      assert_equal 2_09, preorder_charge.fee_cents # 10% gumroad flat fee + 50c + 2.9% cc fee + 30c fixed cc fee
    end

    def build_merchant_account_purchase(user:, link:, chargeable:)
      build_purchase(seller: user, link:, price_cents: link.price_cents, fee_cents: 30, purchase_state: "in_progress",
                     merchant_account: nil, chargeable:,
                     full_name: "Edgar Gumstein", street_address: "123 Gum Road", state: "CA",
                     city: "San Francisco", zip_code: "94017", country: "United States")
    end

    def create_purchase_2(link:, **attrs)
      create_purchase(link:, price_cents: 20_00, created_at: "2012-03-22",
                      stripe_fingerprint: "shfbeggg5142fff", stripe_transaction_id: "276322276372637263", **attrs)
    end

    def create_membership_purchase_new_sale(link:, **attrs)
      purchase = build_purchase(link:, is_original_subscription_purchase: true, **attrs)
      purchase.variant_attributes = link.tiers.presence
      purchase.save!
      purchase.subscription ||= create_subscription(link:)
      purchase.save!
      purchase
    end

    def create_named_seller(**attrs)
      create_user(name: "Seller", payment_address: "seller-#{unique_suffix}@example.com", **attrs)
    end

    def create_discord_integration(**attrs)
      DiscordIntegration.create!({ server_id: "0", server_name: "Gaming", username: "gumbot" }.merge(attrs))
    end

    def build_shipping_destination(**attrs)
      ShippingDestination.new({ country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 0, multiple_items_rate_cents: 0 }.merge(attrs))
    end

    def create_tos_agreement(user: nil, **attrs)
      TosAgreement.create!({ user: user || create_user, ip: "54.234.242.13" }.merge(attrs))
    end

    def create_user_compliance_info(user: nil, **attrs)
      UserComplianceInfo.create!({
        user: user || create_user,
        first_name: "Chuck", last_name: "Bartowski",
        street_address: "address_full_match", city: "San Francisco",
        state: "California", zip_code: "94107", country: "United States",
        verticals: [Vertical::PUBLISHING], is_business: false, has_sold_before: false,
        individual_tax_id: "000000000", birthday: Date.new(1901, 1, 1),
        dba: "Chuckster", phone: "0000000000",
      }.merge(attrs))
    end

    def create_merchant_account_stripe(user: nil)
      user ||= create_user
      create_tos_agreement(user:)
      create_user_compliance_info(user:)
      merchant_account = StripeMerchantAccountManager.create_account(user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
      StripeMerchantAccountHelper.upload_verification_document(merchant_account.charge_processor_merchant_id)
      # Mirrors StripeMerchantAccountHelper.ensure_charges_enabled (retry Account.retrieve
      # until charges are enabled), but without its RSpec.current_example logging, which is
      # nil under Minitest. Replays the same recorded Account.retrieve interactions.
      account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
      attempts = 0
      while !account.charges_enabled && attempts < StripeMerchantAccountHelper::MAX_ATTEMPTS_TO_WAIT_FOR_CAPABILITIES
        attempts += 1
        account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
      end
      merchant_account
    end

    def assert_sidekiq_enqueued(worker, args:, at: nil)
      job = worker.jobs.find { |j| j["args"] == args }
      assert job, "expected #{worker} to be enqueued with #{args.inspect}"
      assert_in_delta at.to_f, job["at"], 1 if at
    end

    def enqueued_mailer_count(mailer, method)
      enqueued_jobs.count do |job|
        job[:job].respond_to?(:ancestors) && job[:job] <= ActionMailer::MailDeliveryJob &&
          job[:args][0] == mailer.name && job[:args][1] == method.to_s
      end
    end

    def capture_charge_processor_call(returns: nil, call_original: false)
      captured = []
      sc = ChargeProcessor.singleton_class
      sc.send(:alias_method, :__orig_create_payment_intent_or_charge!, :create_payment_intent_or_charge!)
      sc.send(:define_method, :create_payment_intent_or_charge!) do |*args, **kwargs|
        captured << { args:, kwargs: }
        call_original ? send(:__orig_create_payment_intent_or_charge!, *args, **kwargs) : returns
      end
      yield
      captured
    ensure
      sc.send(:alias_method, :create_payment_intent_or_charge!, :__orig_create_payment_intent_or_charge!)
      sc.send(:remove_method, :__orig_create_payment_intent_or_charge!)
    end

    def view_content_button_text(product)
      product.custom_view_content_button_text.presence || "View content"
    end

    def setup_purchase_info_context
      link = create_product_with_pdf_file
      purchase = create_purchase(link:)
      create_product_review(purchase:, rating: 4, message: "This is my review!")
      ObfuscateIds.stubs(:encrypt).returns(1)
      purchase.stubs(:can_contact).returns(false)
      purchase.stubs(:email).returns("hi@gumroad.com")
      purchase.stubs(:formatted_display_price).returns(100)
      [link, purchase]
    end

    def setup_purchase_response_context
      user = create_user(username: "admin2")
      link = create_product(user:, unique_permalink: "unique", custom_permalink: "custom")
      purchase = create_purchase(link:, full_name: "Edgar Gumstein", street_address: "123 Gum Road", country: "United States", zip_code: "94107", state: "CA", city: "San Francisco")
      url_redirect = create_url_redirect
      [link, purchase, url_redirect]
    end

    def purchase_with_presentment(was_tax_excluded_from_price:, quantity: 1, presentment_price_cents: 11_25, presentment_tip_cents: 0)
      purchase = build_purchase(
        price_cents: 10_00,
        total_transaction_cents: 10_00,
        was_purchase_taxable: true,
        was_tax_excluded_from_price:,
        tax_cents: 1_00,
        quantity:
      )
      purchase.save!(validate: false)
      charge_presentment = create_charge_presentment(presentment_total_cents: 12_50)
      create_purchase_presentment(
        purchase:,
        charge_presentment:,
        presentment_price_cents:,
        presentment_tip_cents:,
        presentment_seller_tax_cents: 1_25,
        presentment_gumroad_tax_cents: 0,
        presentment_shipping_cents: 0,
        presentment_total_cents: 12_50
      )
      purchase
    end

    def parse_zip(user_input_zip)
      create_purchase(zip_code: user_input_zip, country: "United States").send(:parsed_zip_from_user_input)
    end

    def successful_purchase_context
      user = create_user
      product = create_physical_product(user:)
      product.skus_enabled = true
      product.save!
      category = create_variant_category(link: product)
      create_variant(variant_category: category)
      create_variant(variant_category: category)
      Product::SkusUpdaterService.new(product:).perform
      sku = Sku.last
      sku.update_column(:max_purchase_count, 10)
      purchase = create_physical_purchase(link: product, variant_attributes: [sku], seller: product.user, purchase_state: "in_progress")
      [product, sku, purchase]
    end

    def licenses_setup
      gifter_email = "gifter@foo.com"
      giftee_email = "giftee@foo.com"
      product = create_product(is_licensed: true)
      gift = create_gift(gifter_email:, giftee_email:, link: product)

      gifter_purchase = create_purchase(link: product, seller: product.user, price_cents: product.price_cents,
                                        email: gifter_email, purchase_state: "in_progress")
      gift.gifter_purchase = gifter_purchase
      gifter_purchase.is_gift_sender_purchase = true
      gifter_purchase.save!

      giftee_purchase = gift.giftee_purchase = create_purchase(link: product, seller: product.user, email: giftee_email, price_cents: 0,
                                                               stripe_transaction_id: nil, stripe_fingerprint: nil,
                                                               is_gift_receiver_purchase: true, purchase_state: "in_progress")
      gift.mark_successful
      gift.save!
      [gifter_purchase, giftee_purchase, product]
    end

    def variant_names_hash_context
      product = create_physical_product(skus_enabled: true)
      category1 = create_variant_category(title: "Size", link: product)
      variant1 = create_variant(variant_category: category1, name: "Small")
      category2 = create_variant_category(title: "Color", link: product)
      variant2 = create_variant(variant_category: category2, name: "Red")
      Product::SkusUpdaterService.new(product:).perform
      [product, variant1, variant2]
    end

    def build_gift(link: nil, gifter_email: nil, giftee_email: nil, **attrs)
      Gift.new({
        link: link || create_product,
        gifter_email: gifter_email || "gifter-#{unique_suffix}@example.com",
        giftee_email: giftee_email || "giftee-#{unique_suffix}@example.com",
      }.merge(attrs))
    end

    def build_physical_purchase(link: nil, **attrs)
      link ||= create_physical_product
      build_purchase(
        link:,
        full_name: "barnabas",
        street_address: "123 barnabas street",
        city: "barnabasville",
        state: "CA",
        country: "United States",
        zip_code: "94114",
        **attrs
      )
    end

    def build_membership_purchase_p3(link: nil, **attrs)
      link ||= create_subscription_product
      build_purchase(link:, is_original_subscription_purchase: true, **attrs)
    end

    def build_recurring_membership_purchase(subscription: nil, link: nil, **attrs)
      link ||= subscription&.link || create_membership_product
      variant_attributes = attrs.delete(:variant_attributes) || link.tiers.presence
      build_purchase(link:, subscription:, is_original_subscription_purchase: false, variant_attributes:, **attrs)
    end

    def create_buyer_user(**attrs)
      user = create_user(buyer_signup: true, **attrs)
      create_purchase(link: create_product, purchaser: user)
      user
    end

    def create_url_redirect(purchase: nil, link: nil, **attrs)
      link ||= (purchase&.link || create_product)
      purchase ||= create_purchase(link:, purchaser: create_user(name: "Gumbot"))
      UrlRedirect.create!({ purchase:, link:, uses: 0, expires_at: "2012-01-11 12:46:23" }.merge(attrs))
    end

    def create_charge(**attrs)
      Charge.create!({
        order: create_order,
        seller: create_user,
        processor: "stripe",
        processor_transaction_id: "ch_#{SecureRandom.hex}",
        payment_method_fingerprint: "pm_#{SecureRandom.hex}",
        merchant_account: create_merchant_account,
        amount_cents: 10_00,
        gumroad_amount_cents: 1_00,
        processor_fee_cents: 20,
        processor_fee_currency: "usd",
        stripe_payment_intent_id: "pi_#{SecureRandom.hex}",
        stripe_setup_intent_id: "seti_#{SecureRandom.hex}",
      }.merge(attrs))
    end

    def create_charge_presentment(charge: nil, **attrs)
      ChargePresentment.create!({
        charge: charge || create_charge,
        processor: StripeChargeProcessor.charge_processor_id,
        presentment_currency: Currency::CAD,
        presentment_total_cents: 13_50,
        presentment_gumroad_amount_cents: 1_35,
        stripe_fx_quote_id: "fxq_#{SecureRandom.hex}",
        stripe_fx_quote_expires_at: 30.minutes.from_now,
        fx_rate: BigDecimal("0.740000000000000"),
      }.merge(attrs))
    end

    def create_purchase_presentment(purchase:, charge_presentment:, **attrs)
      PurchasePresentment.create!({
        purchase:,
        charge_presentment:,
        processor: StripeChargeProcessor.charge_processor_id,
        presentment_currency: Currency::CAD,
        presentment_price_cents: 12_00,
        presentment_tip_cents: 0,
        presentment_seller_tax_cents: 0,
        presentment_gumroad_tax_cents: 1_50,
        presentment_shipping_cents: 0,
        presentment_total_cents: 13_50,
        presentment_gumroad_amount_cents: 1_35,
      }.merge(attrs))
    end

    def create_shipment(purchase: nil, **attrs)
      Shipment.create!({ purchase: purchase || create_purchase(link: create_physical_product) }.merge(attrs))
    end

    def create_bundle_product(bundle:, product:, **attrs)
      BundleProduct.create!({ bundle:, product: }.merge(attrs))
    end

    def create_product_with_files(user: nil, files_count: 2, **attrs)
      product = create_product(user:, **attrs)
      files_count.times do |n|
        create_product_file(link: product, size: 300 * (n + 1), display_name: "link-#{n}-file", description: "product-#{n}-file-description")
      end
      product.reload
      product
    end

    def create_product_with_pdf_file(user: nil, **attrs)
      product = create_product(user:, **attrs)
      create_readable_document(link: product, pagelength: 3, size: 50, display_name: "Display Name", description: "Description")
      product.reload
      product
    end

    def create_product_with_video_file(user: nil, **attrs)
      product = create_product(user:, **attrs)
      create_streamable_video(link: product)
      product.reload
      product
    end

    def create_compliant_user(**attrs)
      create_user(user_risk_state: "compliant", **attrs)
    end

    def create_call_product_available_for_a_year(user: nil, **attrs)
      product = create_call_product(user:, **attrs)
      product.call_availabilities.create!(start_time: 1.day.ago, end_time: 1.year.from_now)
      product
    end

    def create_call_purchase(link: nil, **attrs)
      link ||= create_call_product_available_for_a_year
      purchase = build_purchase(link:, **attrs)
      purchase.call ||= Call.new(
        start_time: 1.day.from_now,
        end_time: 1.day.from_now + 30.minutes,
        call_url: "https://zoom.us/j/gmrd",
        purchase:
      )
      purchase.save!
      purchase
    end

    def setup_shipping_purchase
      @purchase = create_purchase(price_cents: 100_00, chargeable: build_chargeable)

      @purchase.link.price_cents = 100_00
      @purchase.link.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2, one_item_rate_cents: 10_00, multiple_items_rate_cents: 5_00)
      @purchase.link.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::GBR.alpha2, one_item_rate_cents: 5_00, multiple_items_rate_cents: 10_00)
      @purchase.link.is_physical = true
      @purchase.link.require_shipping = true
      @purchase.link.user.save!
    end

    def with_expected_charge_amount(expected_amount_cents)
      captured = []
      original = ChargeProcessor.method(:create_payment_intent_or_charge!)
      ChargeProcessor.define_singleton_method(:create_payment_intent_or_charge!) do |*args, **kwargs, &blk|
        captured << args[2]
        original.call(*args, **kwargs, &blk)
      end
      yield
      assert_includes captured, expected_amount_cents,
                      "expected ChargeProcessor.create_payment_intent_or_charge! called with amount #{expected_amount_cents}, got #{captured.inspect}"
    ensure
      ChargeProcessor.singleton_class.send(:define_method, :create_payment_intent_or_charge!, original)
    end

    def assert_receives_and_calls_original(object, method)
      called = false
      original = object.method(method)
      object.define_singleton_method(method) do |*args, **kwargs, &blk|
        called = true
        original.call(*args, **kwargs, &blk)
      end
      yield
      assert called, "expected #{object.class}##{method} to be called"
    end

    def assert_same_records(expected, actual)
      assert_equal expected.map(&:id).sort, actual.to_a.map(&:id).sort
    end

    def reset_purchases!
      Purchase.delete_all
    end

    def free_trial_product
      create_membership_product(free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week)
    end

    def setup_active_subscription_purchase
      subscription = create_subscription
      purchase = create_purchase(subscription:, is_original_subscription_purchase: true)
      [subscription, purchase]
    end

    def build_membership_purchase_p4(link: nil, tier: nil, **attrs)
      link ||= create_membership_product
      purchase = build_purchase(link:, is_original_subscription_purchase: true, **attrs)
      purchase.variant_attributes = tier ? [tier] : link.tiers
      purchase
    end

    def build_free_trial_membership_purchase(link: nil, **attrs)
      link ||= free_trial_product
      build_purchase(
        link:,
        is_original_subscription_purchase: true,
        is_free_trial_purchase: true,
        should_exclude_product_review: true,
        purchase_state: "not_charged",
        succeeded_at: nil,
        **attrs
      )
    end

    def build_free_purchase(link:, seller: :default, **attrs)
      build_purchase(link:, seller:, price_cents: 0, card_type: nil, card_visual: nil, **attrs)
    end

    def build_paypal_in_progress_purchase
      build_purchase(
        purchase_state: "in_progress",
        save_card: true,
        chargeable: build_paypal_chargeable,
        charge_processor_id: BraintreeChargeProcessor.charge_processor_id,
        merchant_account: gumroad_braintree_merchant_account,
      )
    end

    def gumroad_braintree_merchant_account
      MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id) ||
        MerchantAccount.create!(
          charge_processor_id: BraintreeChargeProcessor.charge_processor_id,
          charge_processor_merchant_id: "braintree_#{unique_suffix}",
          charge_processor_alive_at: Time.current
        )
    end

    def create_recurring_membership_purchase_with_original(**attrs)
      link = create_membership_product
      purchase = build_purchase(link:, is_original_subscription_purchase: false, **attrs)
      purchase.variant_attributes = link.tiers
      purchase.save!
      purchase.subscription = create_subscription(link:)
      purchase.subscription.purchases << build_membership_purchase_p4
      purchase.save!
      purchase
    end

    def create_active_follower(email:, user: nil, followed_id: nil, **attrs)
      # `user` and `followed_id` name the same followee (Follower belongs_to :user via
      # followed_id). Only pass whichever the caller supplied — passing an explicit
      # followed_id: nil alongside user: would blank out the user-derived value.
      args = { email:, confirmed_at: Time.current }
      args[:user] = user if user
      args[:followed_id] = followed_id if followed_id
      Follower.create!(args.merge(attrs))
    end

    def setup_unsubscribe_buyer
      seller_a = create_user
      seller_b = create_user
      buyer = create_user

      product_1_by_seller_a = create_product(user: seller_a)
      product_2_by_seller_a = create_product(user: seller_a)
      product_3_by_seller_b = create_product(user: seller_b)

      @purchase_of_product_1 = create_purchase(link: product_1_by_seller_a, email: buyer.email)
      @purchase_of_product_2 = create_purchase(link: product_2_by_seller_a, email: buyer.email)
      @purchase_of_product_3 = create_purchase(link: product_3_by_seller_b, email: buyer.email)

      @follower_of_seller_a = create_active_follower(email: @purchase_of_product_1.email, followed_id: @purchase_of_product_1.seller_id)
      @follower_of_seller_b = create_active_follower(email: @purchase_of_product_3.email, followed_id: @purchase_of_product_3.seller_id)
    end

    def unsubscribe_state
      [
        @purchase_of_product_1.reload.can_contact,
        @purchase_of_product_2.reload.can_contact,
        @purchase_of_product_3.reload.can_contact,
        @follower_of_seller_a.reload.deleted_at.nil?,
        @follower_of_seller_b.reload.deleted_at.nil?
      ]
    end

    def setup_previously_unsubscribed
      @seller = create_user
      @buyer_email = "buyer@example.com"
      @product_1 = create_product(user: @seller)
      @product_2 = create_product(user: @seller)
      first_purchase = create_purchase(link: @product_1, email: @buyer_email, seller: @seller)
      assert_equal true, first_purchase.can_contact
      first_purchase.unsubscribe_buyer
      assert_equal false, first_purchase.reload.can_contact
    end

    def create_refund(purchase:, **attrs)
      Refund.create!({
        purchase:,
        refunding_user_id: create_user.id,
        total_transaction_cents: purchase.total_transaction_cents,
        amount_cents: purchase.price_cents,
        creator_tax_cents: purchase.tax_cents,
        gumroad_tax_cents: purchase.gumroad_tax_cents,
      }.merge(attrs))
    end

    def create_refunded_purchase(link: nil, **attrs)
      link ||= create_product
      purchase = create_purchase(link:, stripe_refunded: true, **attrs)
      create_refund(purchase:, amount_cents: purchase.price_cents)
      purchase
    end

    def create_test_purchase(link: nil, **attrs)
      link ||= create_product
      purchase = create_purchase(link:, purchase_state: "in_progress", purchaser: link.user, email: link.user.email, **attrs)
      purchase.mark_test_successful!
      purchase
    end

    def build_disputed_chargeable
      card = StripePaymentMethodHelper.success_charge_disputed
      Chargeable.new([StripeChargeablePaymentMethod.new(card.to_stripejs_payment_method_id, zip_code: card[:cc_zipcode], product_permalink: "xx")])
    end

    def create_disputed_purchase(link: nil, **attrs)
      link ||= create_product
      create_purchase(link:, chargeable: build_disputed_chargeable, chargeback_date: Time.current, **attrs)
    end

    def create_purchase_integration(purchase: nil, integration: nil, **attrs)
      purchase ||= create_purchase
      integration ||= create_circle_integration
      purchase.link.active_integrations |= [integration]
      PurchaseIntegration.create!({ purchase:, integration: }.merge(attrs))
    end

    def create_discord_purchase_integration(purchase: nil, integration: nil, **attrs)
      integration ||= create_discord_integration
      create_purchase_integration(purchase:, integration:, discord_user_id: "user-0", **attrs)
    end

    def set_price_and_rate_offer_code(seller:, product:)
      create_tiered_offer_code(
        products: [product], user: seller, for_existing_customers: true,
        ownership_products: [product],
        amount_percentage: 0,
        ownership_duration_tiers: [
          { "months" => 0, "amount_percentage" => 0 },
          { "months" => 12, "amount_percentage" => 50 },
        ]
      )
    end

    def setup_purchase_integrations
      @circle_integration = create_circle_integration
      @discord_integration = create_discord_integration
      product = create_product
      @assoc_purchase = create_purchase(link: product)
      @circle_purchase_integration = create_purchase_integration(integration: @circle_integration, purchase: @assoc_purchase)
      @discord_purchase_integration = create_discord_purchase_integration(integration: @discord_integration, purchase: @assoc_purchase)
    end

    def create_commission_product(user: nil, **attrs)
      Link.create!({ user: user || create_eligible_seller, name: "Commission", price_cents: 200, native_type: Link::NATIVE_TYPE_COMMISSION }.merge(attrs))
    end

    def create_commission_deposit_purchase(link: nil, **attrs)
      link ||= create_commission_product
      credit_card = attrs.delete(:credit_card) || create_credit_card
      purchase = build_purchase(link:, is_commission_deposit_purchase: true, credit_card:, **attrs)
      purchase.set_price_and_rate
      purchase.save!
      purchase
    end

    def create_commission(**attrs)
      Commission.create!({ status: "in_progress", deposit_purchase: create_commission_deposit_purchase }.merge(attrs))
    end

    def create_shipping_purchase(**attrs)
      create_purchase(link: create_product(require_shipping: true), full_name: "Full Name", street_address: "123 Gum Rd",
                      country: "United States", state: "NY", city: "New York", zip_code: "10025", **attrs)
    end

    # Every per-purchase flow-of-funds carries the same currencies as the combined charge
    # (issued/gumroad in USD, settled/gross/net in CAD) — build_flow_of_funds_from_combined_charge
    # copies each Amount's currency verbatim. Assert them on every purchase in every split test.
    def assert_combined_charge_currencies(flow_of_funds)
      assert_equal Currency::USD, flow_of_funds.issued_amount.currency
      assert_equal Currency::CAD, flow_of_funds.settled_amount.currency
      assert_equal Currency::USD, flow_of_funds.gumroad_amount.currency
      assert_equal Currency::CAD, flow_of_funds.merchant_account_gross_amount.currency
      assert_equal Currency::CAD, flow_of_funds.merchant_account_net_amount.currency
    end

    def build_flow_of_funds_charge
      charge = create_charge(amount_cents: 100_00, gumroad_amount_cents: 10_00)

      purchase1 = create_purchase(total_transaction_cents: 20_00)
      purchase1.update!(fee_cents: 2_00)
      purchase2 = create_purchase(total_transaction_cents: 30_00)
      purchase2.update!(fee_cents: 3_00)
      purchase3 = create_purchase(total_transaction_cents: 50_00)
      purchase3.update!(fee_cents: 5_00)

      charge.purchases << purchase1
      charge.purchases << purchase2
      charge.purchases << purchase3

      [charge, purchase1, purchase2, purchase3]
    end

    def build_india_mandate_credit_card(card_country:)
      CreditCard.create!(
        card_type: CardType::VISA,
        visual: "**** **** **** 4242",
        stripe_fingerprint: "india_mandate_check_fp",
        stripe_customer_id: "cus_india_mandate_check",
        expiry_month: 12,
        expiry_year: 5.years.from_now.year,
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        card_country:
      )
    end

    def build_india_mandate_charge_purchase(is_original_subscription_purchase:, card: nil, card_country: "IN")
      card ||= build_india_mandate_credit_card(card_country: "IN")
      product = create_membership_product
      subscription = create_subscription(link: product, credit_card: card)
      original_purchase = create_purchase_in_progress(link: product, subscription:, credit_card: card,
                                                      charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                                      card_country:, is_original_subscription_purchase: true)
      return original_purchase if is_original_subscription_purchase

      # Renewal purchases validate their price against the subscription's original
      # purchase, so that record must exist before the renewal can be created.
      create_purchase_in_progress(link: product, subscription:, credit_card: card,
                                  charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                  card_country:, is_original_subscription_purchase: false)
    end

    def build_india_mandate_processor_charge(mandate: nil)
      stripe_charge = BaseProcessorCharge.new
      stripe_charge.charge_processor_id = StripeChargeProcessor.charge_processor_id
      stripe_charge.id = "ch_india_registration"
      stripe_charge.refunded = false
      stripe_charge.card_fingerprint = "card-fingerprint"
      stripe_charge.card_mandate = mandate
      stripe_charge.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 100)
      stripe_charge
    end

    def build_india_mandate_setup_intent_purchase(card_country: "IN", setup_intent_id: "seti_india_registration")
      card = build_india_mandate_credit_card(card_country:)
      product = create_membership_product
      subscription = create_subscription(link: product, credit_card: card)
      create_purchase_in_progress(link: product, subscription:, credit_card: card,
                                  charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                  card_country:, is_original_subscription_purchase: true,
                                  processor_setup_intent_id: setup_intent_id)
    end

    def stub_india_mandate_setup_intent(succeeded: true, mandate: nil)
      setup_intent = mock("setup_intent")
      setup_intent.stubs(:succeeded?).returns(succeeded)
      setup_intent.stubs(:mandate).returns(mandate)
      ChargeProcessor.stubs(:get_setup_intent).returns(setup_intent)
      setup_intent
    end

    def build_refund_policy_purchase
      purchase = create_purchase
      refund_policy = purchase.create_purchase_refund_policy!(title: "Refund policy", fine_print: "This is the fine print.", max_refund_period_in_days: 30)
      purchase.stubs(:purchase_refund_policy).returns(refund_policy)
      [purchase, refund_policy]
    end

    def build_offer_code_line_item_purchase(product:, seller:, offer_code:)
      purchase = build_purchase(link: product, seller:, offer_code:, quantity: 1, purchase_state: "in_progress")
      purchase.save(validate: false)
      purchase
    end

    def build_call(start_time: 1.day.from_now, end_time: nil, purchase: nil, **attrs)
      end_time ||= start_time + 30.minutes
      Call.new({ start_time:, end_time:, call_url: "https://zoom.us/j/gmrd", purchase: }.merge(attrs))
    end

    def build_call_purchase(call: nil, link: nil, **attrs)
      link ||= create_call_product_available_for_a_year
      purchase = build_purchase(link:, **attrs)
      purchase.call = call || build_call(purchase:)
      purchase
    end
end
