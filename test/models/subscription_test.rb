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

  # --- #subscription_mobile_json_data ----------------------------------------

  # Rebuilds the section's `before` context. Called inside the cassette block
  # because the buyer's saved card is tokenized against Stripe.
  def build_mobile_json_context
    travel_to Time.current
    @product = create_subscription_product(user: create_user)
    @user = create_user(credit_card: create_credit_card)
    @very_old_installment = create_installment(name: "very old installment", link: @product, created_at: 5.months.ago, published_at: 5.months.ago)
    @old_installment = create_installment(name: "old installment", link: @product, created_at: 4.months.ago, published_at: 4.months.ago)
    @new_installment = create_installment(name: "new installment", link: @product, created_at: Time.current, published_at: Time.current)
    @unpublished_installment = create_installment(link: @product, published_at: nil)

    @workflow = create_workflow(seller: @product.user, link: @product, created_at: 13.months.ago, published_at: 13.months.ago)
    @workflow_installment = create_installment(name: "workflow installment", link: @product, workflow: @workflow, published_at: 13.months.ago)
    @workflow_installment_rule = create_installment_rule(installment: @workflow_installment, delayed_delivery_time: 1.day)

    @subscription = create_subscription(link: @product, user: @user, created_at: 1.year.ago)
    @purchase = create_purchase(is_original_subscription_purchase: true, link: @product, subscription: @subscription, purchaser: @user, created_at: @subscription.created_at)
  end

  test "#subscription_mobile_json_data returns nothing if the subscription is no longer alive" do
    VCR.use_cassette("Subscription/_subscription_mobile_json_data/returns_nothing_if_the_subscription_is_no_longer_alive") do
      build_mobile_json_context
      @subscription.cancel_effective_immediately!
      assert_nil @subscription.subscription_mobile_json_data
    end
  end

  test "#subscription_mobile_json_data returns the correct json format for the mobile api" do
    VCR.use_cassette("Subscription/_subscription_mobile_json_data/returns_the_correct_json_format_for_the_mobile_api") do
      build_mobile_json_context
      create_email_info(purchase: @purchase, installment: @workflow_installment, state: "created")
      create_email_info(purchase: @purchase, installment: @very_old_installment, state: "created")
      create_email_info(purchase: @purchase, installment: @old_installment, state: "created")
      create_email_info(purchase: @purchase, installment: @new_installment, state: "created")
      [@subscription, @purchase, @product].each(&:reload)
      subscription_mobile_json_data = @subscription.subscription_mobile_json_data.to_json
      expected_subscription_data = @product.as_json(mobile: true)
      subscription_data = {
        subscribed_at: @subscription.created_at,
        external_id: @subscription.external_id,
        recurring_amount: @subscription.original_purchase.formatted_display_price
      }
      expected_subscription_data[:subscription_data] = subscription_data
      expected_subscription_data[:purchase_id] = @purchase.external_id
      expected_subscription_data[:purchased_at] = @purchase.created_at
      expected_subscription_data[:user_id] = @purchase.purchaser.external_id
      expected_subscription_data[:can_contact] = @purchase.can_contact
      expected_subscription_data[:updates_data] = @subscription.updates_mobile_json_data
      assert_equal 4, @subscription.subscription_mobile_json_data[:updates_data].length
      expected_updates_data = [
        @workflow_installment.installment_mobile_json_data(purchase: @purchase, subscription: @subscription),
        @very_old_installment.installment_mobile_json_data(purchase: @purchase, subscription: @subscription),
        @old_installment.installment_mobile_json_data(purchase: @purchase, subscription: @subscription),
        @new_installment.installment_mobile_json_data(purchase: @purchase, subscription: @subscription)
      ]
      assert_equal expected_updates_data.sort_by { |h| h[:name] }.to_json, @subscription.subscription_mobile_json_data[:updates_data].sort_by { |h| h[:name] }.to_json
      assert_equal expected_subscription_data.to_json, subscription_mobile_json_data
    end
  end

  test "#subscription_mobile_json_data includes the first installment for new subscribers if the creator set should_include_last_post to true" do
    VCR.use_cassette("Subscription/_subscription_mobile_json_data/includes_the_first_installment_for_new_subscribers_if_the_creator_set_should_include_last_post_to_true") do
      build_mobile_json_context
      product = create_membership_product
      product.should_include_last_post = true
      product.save!
      user = create_user
      installment = create_installment(link: product, published_at: 1.day.ago)
      subscription = create_subscription(link: product, user:)
      # A tiered membership stores its price on the tiers, so the product's own
      # price_cents column is 0; an original purchase left at $0 fails the "must
      # be chargeable" validation. The RSpec :purchase factory read a non-zero
      # link.price_cents here, so pass the $1 price explicitly to match.
      purchase = create_purchase(is_original_subscription_purchase: true, link: product, subscription:, purchaser: user, price_cents: 100)
      create_email_info(purchase:, installment:, state: "created")
      assert_equal 1, subscription.updates_mobile_json_data.length
      assert_equal installment.external_id, subscription.updates_mobile_json_data.first[:external_id]
    end
  end

  # --- #installments ---------------------------------------------------------

  def build_installments_context
    @product = create_subscription_product(user: create_user)
    @user = create_user(credit_card: create_credit_card)
    @subscription = create_subscription(link: @product, user: @user, created_at: 3.days.ago)
    @purchase = create_purchase(is_original_subscription_purchase: true, link: @product, subscription: @subscription, purchaser: @user)
    @very_old_installment = create_installment(link: @product, created_at: 5.months.ago, published_at: 5.months.ago)
    @old_installment = create_installment(link: @product, created_at: 4.months.ago, published_at: 4.months.ago)
    @new_installment = create_installment(link: @product, published_at: Time.current)
    @unpublished_installment = create_installment(link: @product, published_at: nil)
  end

  test "#installments returns the installments made after subscription created, plus the last one made before the subscription if link option is set" do
    VCR.use_cassette("Subscription/_installments/returns_the_installments_made_after_subscription_created_plus_the_last_one_made_before_the_subscription_if_link_option_is_set") do
      build_installments_context
      @product.update_attribute(:should_include_last_post, true)
      assert_equal [@old_installment, @new_installment], @subscription.installments
    end
  end

  test "#installments returns the installments made after subscription created, plus the last one made before the subscription if link option is set, ordered with published_at date" do
    VCR.use_cassette("Subscription/_installments/returns_the_installments_made_after_subscription_created_plus_the_last_one_made_before_the_subscription_if_link_option_is_set_ordered_with_published_at_date") do
      build_installments_context
      @product.update_attribute(:should_include_last_post, true)
      old_installment1 = create_installment(link: @product, published_at: 4.days.ago)
      create_installment(link: @product, published_at: 5.days.ago)
      assert_equal [old_installment1, @new_installment], @subscription.installments
    end
  end

  test "#installments returns the installments made after subscription created without the last one made before the subscription if link option is not set" do
    VCR.use_cassette("Subscription/_installments/returns_the_installments_made_after_subscription_created_without_the_last_one_made_before_the_subscription_if_link_option_is_not_set") do
      build_installments_context
      assert_equal [@new_installment], @subscription.installments
    end
  end

  test "#installments does not include unpublished installments" do
    VCR.use_cassette("Subscription/_installments/does_not_include_unpublished_installments") do
      build_installments_context
      assert_not_includes @subscription.installments, @unpublished_installment
    end
  end

  test "#installments does not include any installment older than the last installment before the creation of the subscription" do
    VCR.use_cassette("Subscription/_installments/does_not_include_any_installment_older_than_the_last_installment_before_the_creation_of_the_subscription") do
      build_installments_context
      assert_not_includes @subscription.installments, @very_old_installment
    end
  end

  def build_cancelled_installments_context
    @product = create_subscription_product(user: create_user, is_recurring_billing: true)
    @user = create_user(credit_card: create_credit_card)
    @subscription = create_subscription(link: @product, user: @user, created_at: 5.months.ago, cancelled_at: 3.months.ago)
    @purchase = create_purchase(is_original_subscription_purchase: true, link: @product, subscription: @subscription, purchaser: @user)
    @very_old_installment = create_installment(link: @product, created_at: 7.months.ago, published_at: 7.months.ago)
    @old_installment = create_installment(link: @product, created_at: 6.months.ago, published_at: 6.months.ago)
    @correct_installment = create_installment(link: @product, created_at: 4.months.ago, published_at: 4.months.ago)
    @current_installment = create_installment(link: @product, created_at: Time.current, published_at: Time.current)
  end

  test "#installments cancelled subscriptions returns installment created while subscription active, plus the last installment before the subscription was created" do
    VCR.use_cassette("Subscription/_installments/cancelled_subscriptions/returns_installment_created_while_subscription_active_plus_the_last_installment_before_the_subscription_was_created") do
      build_cancelled_installments_context
      assert_equal [@correct_installment], @subscription.installments
    end
  end

  test "#installments cancelled subscriptions does not include any installment older than the last installment before the creation of the subscription if link option is set" do
    VCR.use_cassette("Subscription/_installments/cancelled_subscriptions/does_not_include_any_installment_older_than_the_last_installment_before_the_creation_of_the_subscription_if_link_option_is_set") do
      build_cancelled_installments_context
      @product.update_attribute(:should_include_last_post, true)
      assert_not_includes @subscription.installments, @very_old_installment
      assert_includes @subscription.installments, @old_installment
    end
  end

  test "#installments cancelled subscriptions does not include any past installments if link option is not set" do
    VCR.use_cassette("Subscription/_installments/cancelled_subscriptions/does_not_include_any_past_installments_if_link_option_is_not_set") do
      build_cancelled_installments_context
      assert_not_includes @subscription.installments, @old_installment
    end
  end

  test "#installments cancelled subscriptions does not return installments created after subscription cancelled" do
    VCR.use_cassette("Subscription/_installments/cancelled_subscriptions/does_not_return_installments_created_after_subscription_cancelled") do
      build_cancelled_installments_context
      assert_not_includes @subscription.installments, @current_installment
    end
  end

  def build_failed_installments_context
    @product = create_subscription_product(user: create_user, is_recurring_billing: true)
    @user = create_user(credit_card: create_credit_card)
    @subscription = create_subscription(link: @product, user: @user, created_at: 5.months.ago, failed_at: 3.months.ago)
    @purchase = create_purchase(is_original_subscription_purchase: true, link: @product, subscription: @subscription, purchaser: @user)
    @old_installment = create_installment(link: @product, created_at: 6.months.ago, published_at: 6.months.ago)
    @very_old_installment = create_installment(link: @product, created_at: 7.months.ago, published_at: 7.months.ago)
    @correct_installment = create_installment(link: @product, created_at: 4.months.ago, published_at: 4.months.ago)
    @end_of_month_failed = create_installment(link: @product, created_at: 3.months.ago.at_end_of_month, published_at: 3.months.ago.at_end_of_month)
    @current_installment = create_installment(link: @product, created_at: Time.current, published_at: Time.current)
  end

  test "#installments failed subscriptions returns installment created while subscription active, plus the last installment before the subscription was created if link option is set" do
    VCR.use_cassette("Subscription/_installments/failed_subscriptions/returns_installment_created_while_subscription_active_plus_the_last_installment_before_the_subscription_was_created_if_link_option_is_set") do
      build_failed_installments_context
      @product.update_attribute(:should_include_last_post, true)
      assert_equal [@old_installment, @correct_installment], @subscription.installments
    end
  end

  test "#installments failed subscriptions returns only the installment created while subscription active if link option is not set" do
    VCR.use_cassette("Subscription/_installments/failed_subscriptions/returns_only_the_installment_created_while_subscription_active_if_link_option_is_not_set") do
      build_failed_installments_context
      assert_equal [@correct_installment], @subscription.installments
    end
  end

  test "#installments failed subscriptions does not include any installment older than the last installment before the creation of the subscription" do
    VCR.use_cassette("Subscription/_installments/failed_subscriptions/does_not_include_any_installment_older_than_the_last_installment_before_the_creation_of_the_subscription") do
      build_failed_installments_context
      assert_not_includes @subscription.installments, @very_old_installment
    end
  end

  test "#installments failed subscriptions does not return installment created in the month that subscription failed" do
    VCR.use_cassette("Subscription/_installments/failed_subscriptions/does_not_return_installment_created_in_the_month_that_subscription_failed") do
      build_failed_installments_context
      # The RSpec original references @end_of_month_cancelled, which is never
      # assigned (a typo for @end_of_month_failed) and so is nil. Preserved 1:1 —
      # the assertion is trivially true either way.
      assert_not_includes @subscription.installments, @end_of_month_cancelled
    end
  end

  test "#installments failed subscriptions does not return installments created after subscription failed" do
    VCR.use_cassette("Subscription/_installments/failed_subscriptions/does_not_return_installments_created_after_subscription_failed") do
      build_failed_installments_context
      assert_not_includes @subscription.installments, @current_installment
    end
  end

  test "#installments workflow installments does not include any workflow installment" do
    VCR.use_cassette("Subscription/_installments/workflow_installments/does_not_include_any_workflow_installment") do
      @product = create_subscription_product(user: create_user, is_recurring_billing: true)
      @user = create_user(credit_card: create_credit_card)
      @workflow = create_workflow(seller: @product.user, link: @product, published_at: 1.week.ago)
      @workflow_installment = create_installment(link: @product, workflow: @workflow, published_at: Time.current)
      @workflow_installment_rule = create_installment_rule(installment: @workflow_installment, delayed_delivery_time: 1.day)
      @subscription = create_subscription(link: @product, user: @user, created_at: 5.months.ago, failed_at: 3.months.ago)
      @purchase = create_purchase(is_original_subscription_purchase: true, link: @product, subscription: @subscription, purchaser: @user)

      assert_equal 0, @subscription.installments.length
    end
  end
end
