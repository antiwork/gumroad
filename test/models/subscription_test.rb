# frozen_string_literal: true

require "test_helper"

# Ported from spec/models/subscription_spec.rb (#2 in the #5801 factory-time
# ranking: 1:02 setup, 79% factory). Subscription is exercised through model
# logic — billing lifecycle, charges, cancellation, resubscription — so objects
# are built with the shared ModelFactories helpers. HTTP-touching paths replay
# the existing RSpec cassettes via the VCR bridge (#5938).
#
# The RSpec file nests describe/context/it; this suite uses flat `test "..."`
# methods (same as asset_preview_test), so the nesting is folded into the test
# name and per-section `before` blocks become small setup helpers invoked at the
# top of each test.
class SubscriptionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @seller = create_user
    # The platform Stripe account (user_id nil) comes from the merchant_accounts
    # fixture; the RSpec `before` created it on demand, but here it's seeded.
    @product = create_subscription_product(user: @seller, is_licensed: true)
    @subscription = create_subscription(user: create_user, link: @product)
    @purchase = create_purchase(
      link: @product,
      email: @subscription.user.email,
      full_name: "squiddy",
      price_cents: @product.price_cents,
      is_original_subscription_purchase: true,
      subscription: @subscription,
      created_at: 2.days.ago
    )
  end

  # --- associations ----------------------------------------------------------

  test "#latest_plan_change returns the most recent, live plan change" do
    create_subscription_plan_change(subscription: @subscription, created_at: 1.month.ago)
    most_recent = create_subscription_plan_change(subscription: @subscription, created_at: 1.day.ago)
    create_subscription_plan_change(subscription: @subscription, created_at: 1.week.ago)
    create_subscription_plan_change(subscription: @subscription, created_at: 1.hour.ago, deleted_at: Time.current)

    assert_equal most_recent, @subscription.latest_plan_change
  end

  test "#latest_applicable_plan_change returns the most recent, live plan change that is applicable" do
    create_subscription_plan_change(subscription: @subscription, created_at: 2.weeks.ago, deleted_at: 1.week.ago)
    create_subscription_plan_change(subscription: @subscription, created_at: 10.days.ago, applied: true)

    create_subscription_plan_change(subscription: @subscription, created_at: 5.days.ago, for_product_price_change: true, effective_on: 1.week.from_now)
    create_subscription_plan_change(subscription: @subscription, created_at: 4.days.ago, for_product_price_change: true, effective_on: 2.days.ago, notified_subscriber_at: nil)
    create_subscription_plan_change(subscription: @subscription, created_at: 3.days.ago, for_product_price_change: true, effective_on: 1.day.ago, notified_subscriber_at: 1.day.ago, deleted_at: 12.hours.ago)
    create_subscription_plan_change(subscription: @subscription, created_at: 2.days.ago, for_product_price_change: true, effective_on: 1.day.ago, notified_subscriber_at: 1.day.ago, applied: true)

    most_recent = create_subscription_plan_change(subscription: @subscription, created_at: 1.day.ago, for_product_price_change: true, effective_on: 1.day.ago, notified_subscriber_at: 1.day.ago)

    assert_equal most_recent, @subscription.latest_applicable_plan_change
  end

  # --- lifecycle hooks -------------------------------------------------------

  test "create_interruption_event records a deactivated event if deactivated_at is set and was previously blank" do
    freeze_time do
      first_deactivation = 1.week.ago
      assert_changes -> { @subscription.reload.subscription_events.deactivated.count }, from: 0, to: 1 do
        @subscription.update!(deactivated_at: first_deactivation)
        assert_equal first_deactivation, @subscription.reload.subscription_events.deactivated.last.occurred_at
      end

      assert_no_changes -> { @subscription.reload.subscription_events.deactivated.count } do
        @subscription.update!(deactivated_at: Time.current)
        assert_equal first_deactivation, @subscription.reload.subscription_events.deactivated.last.occurred_at
      end

      assert_changes -> { SubscriptionEvent.deactivated.count }, from: 1, to: 2 do
        create_subscription(deactivated_at: Time.current)
      end
    end
  end

  test "create_interruption_event records a restarted event if deactivated_at is cleared" do
    freeze_time do
      @subscription.update!(deactivated_at: Time.current)
      assert_changes -> { @subscription.reload.subscription_events.restarted.count }, from: 0, to: 1 do
        @subscription.update!(deactivated_at: nil)
        assert_equal Time.current, @subscription.reload.subscription_events.restarted.last.occurred_at
      end
    end
  end

  test "create_interruption_event does nothing if deactivated_at has not changed" do
    assert_no_changes -> { @subscription.reload.subscription_events.count } do
      @subscription.update!(failed_at: Time.current)
    end
  end

  test "send_ended_notification_webhook sends a 'subscription_ended' notification if the subscription has just been deactivated" do
    @subscription.update!(deactivated_at: Time.current)
    assert PostToPingEndpointsWorker.jobs.any? { |job| job["args"] == [nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, @subscription.id] }
  end

  test "send_ended_notification_webhook does not send a 'subscription_ended' notification if the subscription was already deactivated" do
    @subscription.update!(deactivated_at: Time.current)
    Sidekiq::Worker.clear_all

    @subscription.update!(deactivated_at: Time.current)
    assert PostToPingEndpointsWorker.jobs.none? { |job| job["args"] == [nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, @subscription.id] }
  end

  test "send_ended_notification_webhook does not send a 'subscription_ended' notification if the subscription is not deactivated" do
    @subscription.update!(cancelled_at: Time.current)
    assert PostToPingEndpointsWorker.jobs.none? { |job| job["args"] == [nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, @subscription.id] }
  end

  test "creation sets the seller" do
    assert_equal @purchase.seller, @subscription.seller
  end

  # --- scopes: .active_without_pending_cancel --------------------------------

  test ".active_without_pending_cancel returns only active subscriptions" do
    assert_equal [@subscription], Subscription.active_without_pending_cancel.to_a
  end

  test ".active_without_pending_cancel returns nothing when subscription is a test" do
    @subscription.update!(is_test_subscription: true)
    assert_empty Subscription.active_without_pending_cancel
  end

  test ".active_without_pending_cancel returns nothing when subscription has failed" do
    @subscription.update!(failed_at: 1.minute.ago)
    assert_empty Subscription.active_without_pending_cancel
  end

  test ".active_without_pending_cancel returns nothing when subscription has ended" do
    @subscription.update!(ended_at: 1.minute.ago)
    assert_empty Subscription.active_without_pending_cancel
  end

  test ".active_without_pending_cancel returns nothing when subscription was cancelled" do
    @subscription.update!(cancelled_at: 1.minute.ago)
    assert_empty Subscription.active_without_pending_cancel
  end

  test ".active_without_pending_cancel returns nothing when subscription is pending cancellation" do
    @subscription.update!(cancelled_at: 1.minute.from_now)
    assert_empty Subscription.active_without_pending_cancel
  end

  # --- #as_json --------------------------------------------------------------

  test "#as_json returns the expected JSON representation" do
    expected = {
      id: @subscription.external_id,
      email: @subscription.email,
      product_id: @subscription.link.external_id,
      product_name: @subscription.link.name,
      user_id: @subscription.user.external_id,
      user_email: @subscription.user.email,
      purchase_ids: @subscription.purchases.map(&:external_id),
      created_at: @subscription.created_at,
      cancelled_at: @subscription.cancelled_at,
      user_requested_cancellation_at: @subscription.user_requested_cancellation_at,
      charge_occurrence_count: @subscription.charge_occurrence_count,
      recurrence: @subscription.recurrence,
      ended_at: @subscription.ended_at,
      failed_at: @subscription.failed_at,
      free_trial_ends_at: @subscription.free_trial_ends_at,
      status: @subscription.status
    }

    assert_equal expected, @subscription.as_json
  end

  test "#as_json excludes 'not_charged' plan change purchases" do
    purchase = create_purchase(link: @product, subscription: @subscription, purchase_state: "not_charged")
    assert_not_includes @subscription.as_json[:purchase_ids], purchase.external_id
  end

  test "#as_json excludes failed purchases" do
    failed_purchase = create_failed_purchase(link: @product, subscription: @subscription)
    assert_not_includes @subscription.as_json[:purchase_ids], failed_purchase.external_id
  end

  test "#as_json includes free trial 'not_charged' purchases" do
    purchase = create_free_trial_membership_purchase
    assert_equal [purchase.external_id], purchase.subscription.as_json[:purchase_ids]
  end

  test "#as_json includes license_key for membership products with licensing enabled" do
    license = create_license(link: @product, purchase: @purchase)

    assert_equal license.serial, @subscription.as_json[:license_key]
  end

  # --- #credit_card_to_charge ------------------------------------------------

  # The whole RSpec describe carries `:vcr`, so credit-card creation — which
  # tokenizes a card against the Stripe API — is replayed from the cassette the
  # RSpec metadata derived from each context/it path.
  test "#credit_card_to_charge returns nil when test subscription" do
    VCR.use_cassette("Subscription/_credit_card_to_charge/when_test_subscription/returns_nil") do
      user = create_user(credit_card: create_credit_card)
      product = create_subscription_product(user:)
      subscription = create_subscription(link: product, user:, is_test_subscription: true)

      assert_nil subscription.credit_card_to_charge
    end
  end

  test "#credit_card_to_charge returns the credit card used with the original purchase for a guest subscription purchase" do
    VCR.use_cassette("Subscription/_credit_card_to_charge/when_guest_subscription_purchase/returns_the_credit_card_used_with_the_original_purchase") do
      user = create_user
      product = create_subscription_product(user:)
      original_purchase_card = create_credit_card
      subscription = create_subscription(link: product, user: nil, credit_card: original_purchase_card)

      assert_equal original_purchase_card, subscription.credit_card_to_charge
    end
  end

  test "#credit_card_to_charge returns the card saved on file when the user has one and there is no card in the purchase" do
    VCR.use_cassette("Subscription/_credit_card_to_charge/when_user_has_a_card_saved_on_file_and_doesn_t_have_a_card_in_the_purchase/returns_the_card_saved_on_file_not_the_card_used_during_purchase") do
      buyers_card = create_credit_card
      user = create_user(credit_card: buyers_card)
      product = create_subscription_product(user:)
      subscription = create_subscription(link: product, user:)

      assert_equal buyers_card, subscription.credit_card_to_charge
    end
  end

  test "#credit_card_to_charge returns the subscription's card when the user has a card associated to the subscription" do
    VCR.use_cassette("Subscription/_credit_card_to_charge/when_user_has_a_card_associated_to_the_subscription/returns_the_subscription_s_card") do
      buyers_card = create_credit_card
      subscription_card = create_credit_card
      user = create_user(credit_card: buyers_card)
      product = create_subscription_product(user:)
      subscription = create_subscription(link: product, user:, credit_card: subscription_card)

      assert_equal subscription_card, subscription.credit_card_to_charge
    end
  end
end
