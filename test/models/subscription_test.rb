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
      purchase = create_purchase(is_original_subscription_purchase: true, link: product, subscription:, purchaser: user)
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

  # --- #charge! --------------------------------------------------------------

  test "#charge! uses the authenticated buyer when resolving charge discounts" do
    ownership_product = create_product(user: @product.user)
    authenticated_buyer = create_user
    create_purchase(link: ownership_product, seller: @product.user, purchaser: authenticated_buyer, price_cents: ownership_product.price_cents)
    offer_code = create_offer_code(
      code: "authenticatedbuyer",
      user: @product.user,
      products: [@product],
      ownership_products: [ownership_product],
      existing_customers_only: true,
      amount_cents: nil,
      amount_percentage: 1,
      currency_type: nil
    )
    # Short-circuit the actual charge: return the built purchase untouched so the
    # test only exercises discount resolution (mirrors the RSpec stub of
    # process_purchase!). No HTTP happens, so no cassette is needed here.
    @subscription.define_singleton_method(:process_purchase!) { |purchase, *_args, **_kwargs| purchase }

    new_purchase = @subscription.charge!(authenticated_offer_code_buyer: authenticated_buyer)

    assert_equal offer_code, new_purchase.offer_code
    assert_equal 1, new_purchase.purchase_offer_code_discount.offer_code_amount
    assert_equal true, new_purchase.purchase_offer_code_discount.offer_code_is_percent
  end

  # The second RSpec `#charge!` describe adds a card to the subscriber before
  # each example; replayed via cassette because card tokenization hits Stripe.
  def charge_section_setup
    @subscription.user.update!(credit_card: create_credit_card)
  end

  test "#charge! creates a new purchase row" do
    VCR.use_cassette("Subscription/_charge_/creates_a_new_purchase_row") do
      charge_section_setup
      assert_changes -> { Purchase.count }, from: Purchase.count, to: Purchase.count + 1 do
        @subscription.charge!
      end
    end
  end

  test "#charge! gives new purchase right attributes" do
    VCR.use_cassette("Subscription/_charge_/gives_new_purchase_right_attributes") do
      charge_section_setup
      new_purchase = @subscription.charge!

      assert_equal "successful", new_purchase.purchase_state
      assert_equal @subscription, new_purchase.subscription
      assert_equal @product, new_purchase.link
      assert_equal @purchase.email, new_purchase.email
      assert_equal @purchase.full_name, new_purchase.full_name
      assert_equal @purchase.ip_address, new_purchase.ip_address
      assert_equal @purchase.ip_country, new_purchase.ip_country
      assert_equal @purchase.ip_state, new_purchase.ip_state
      assert_equal @purchase.referrer, new_purchase.referrer
      assert_equal @purchase.browser_guid, new_purchase.browser_guid
      assert_equal false, new_purchase.is_original_subscription_purchase
      assert_equal @product.price_cents, new_purchase.price_cents
    end
  end

  test "#charge! charges stripe" do
    VCR.use_cassette("Subscription/_charge_/charges_stripe") do
      charge_section_setup
      @subscription.charge!
    end
  end

  test "#charge! creates a purchase event without copying the original buyer email forward" do
    VCR.use_cassette("Subscription/_charge_/creates_a_purchase_event_without_copying_the_original_buyer_email_forward") do
      charge_section_setup
      create_event(purchase_id: @purchase.id, email: @purchase.email)
      recurring_purchase = @subscription.charge!
      purchase_event = Event.last
      assert_equal true, purchase_event.is_recurring_subscription_charge
      assert_equal recurring_purchase.id, purchase_event.purchase_id
      assert_nil purchase_event.email
    end
  end

  test "#charge! uses the previously saved payment instrument to charge an unregistered user's subscription" do
    VCR.use_cassette("Subscription/_charge_/uses_the_previously_saved_payment_instrument_to_charge_an_unregistered_user_s_subscription") do
      charge_section_setup
      discover_cc = CreditCard.create(build_chargeable(card: StripePaymentMethodHelper.success_discover))
      subscription = nil
      travel_to(1.month.ago) do
        subscription = create_subscription(user: nil, link: @product, credit_card: discover_cc)
        create_purchase(is_original_subscription_purchase: true, link: @product, subscription:, credit_card: discover_cc)
      end

      assert_changes -> { Purchase.count }, from: Purchase.count, to: Purchase.count + 1 do
        subscription.charge!
      end

      subscription.reload
      latest_purchase = Purchase.last
      assert_equal "successful", latest_purchase.purchase_state
      assert_equal "**** **** **** 9424", latest_purchase.card_visual
      assert_equal discover_cc, subscription.credit_card
      assert_equal latest_purchase.credit_card, subscription.credit_card
    end
  end

  test "#charge! uses the previously saved payment instrument to charge a registered user's subscription" do
    VCR.use_cassette("Subscription/_charge_/uses_the_previously_saved_payment_instrument_to_charge_a_registered_user_s_subscription") do
      charge_section_setup
      user = create_user
      discover_cc = CreditCard.create(build_chargeable(card: StripePaymentMethodHelper.success_discover))
      user.credit_card = discover_cc
      user.save!

      subscription = nil
      travel_to(1.month.ago) do
        subscription = create_subscription(user:, link: @product, credit_card: discover_cc)
        create_purchase(is_original_subscription_purchase: true, link: @product, subscription:, credit_card: discover_cc)
      end

      assert_changes -> { Purchase.count }, from: Purchase.count, to: Purchase.count + 1 do
        subscription.charge!
      end

      subscription.reload
      latest_purchase = Purchase.last
      assert_equal "successful", latest_purchase.purchase_state
      assert_equal "**** **** **** 9424", latest_purchase.card_visual
      assert_equal discover_cc, subscription.credit_card
      assert_equal latest_purchase.credit_card, subscription.credit_card
    end
  end

  test "#charge! uses the payment instrument attached to the subscription in case the purchaser account does not have a saved payment instrument" do
    VCR.use_cassette("Subscription/_charge_/uses_the_payment_instrument_attached_to_the_subscription_in_case_the_purchaser_account_does_not_have_a_saved_payment_instrument") do
      charge_section_setup
      user = create_user
      discover_cc = CreditCard.create(build_chargeable(card: StripePaymentMethodHelper.success_discover), nil, user)

      subscription = nil
      travel_to(1.month.ago) do
        subscription = create_subscription(user:, link: @product, credit_card: discover_cc)
        create_purchase(is_original_subscription_purchase: true, link: @product, subscription:, credit_card: discover_cc)
      end

      assert_changes -> { Purchase.count }, from: Purchase.count, to: Purchase.count + 1 do
        subscription.charge!
      end

      subscription.reload
      latest_purchase = Purchase.last
      assert_equal "successful", latest_purchase.purchase_state
      assert_equal "**** **** **** 9424", latest_purchase.card_visual
      assert_equal discover_cc, subscription.credit_card
      assert_equal latest_purchase.credit_card, subscription.credit_card
    end
  end

  test "#charge! with an Indian credit card uses the mandate associated with the saved credit card to successfully charge" do
    VCR.use_cassette("Subscription/_charge_/with_an_Indian_credit_card/with_a_successful_mandate/uses_the_mandate_associated_with_the_saved_credit_card_to_successfully_charge") do
      charge_section_setup
      buyer = create_user
      product = create_membership_product_with_preset_tiered_pricing(recurrence_price_values: [
                                                                       { "monthly": { enabled: true, price: 5 } },
                                                                       { "monthly": { enabled: true, price: 8 } }
                                                                     ])
      indian_cc = CreditCard.create(build_chargeable(card: StripePaymentMethodHelper.success_indian_card_mandate), nil, buyer)
      indian_cc.update!(
        json_data: { stripe_payment_intent_id: "pi_3SOdR0IBOqvOFDrf1MBxDys4" },
        processor_payment_method_id: "pm_1SOdQxIBOqvOFDrfANv6cZO4",
        stripe_customer_id: "cus_TLK5KncEpdGdIH"
      )
      subscription = create_subscription(link: product, user: buyer, credit_card: indian_cc)
      create_membership_purchase(is_original_subscription_purchase: true, link: product, variant_attributes: [product.default_tier],
                                 price_cents: 5_00, subscription:, purchaser: buyer, credit_card: indian_cc)

      assert_changes -> { Purchase.count }, from: Purchase.count, to: Purchase.count + 1 do
        subscription.charge!
      end

      subscription.reload
      latest_purchase = Purchase.last

      assert_equal "in_progress", latest_purchase.purchase_state
      assert_equal indian_cc, subscription.credit_card
      assert_equal latest_purchase.credit_card, subscription.credit_card
    end
  end

  test "#charge! with an Indian credit card uses the mandate associated with the saved credit card and fails" do
    VCR.use_cassette("Subscription/_charge_/with_an_Indian_credit_card/with_a_cancelled_mandate/uses_the_mandate_associated_with_the_saved_credit_card_and_fails") do
      charge_section_setup
      buyer = create_user
      product = create_membership_product_with_preset_tiered_pricing(recurrence_price_values: [
                                                                       { "monthly": { enabled: true, price: 5 } },
                                                                       { "monthly": { enabled: true, price: 8 } }
                                                                     ])
      indian_cc = CreditCard.create(build_chargeable(card: StripePaymentMethodHelper.cancelled_indian_card_mandate), nil, buyer)
      indian_cc.update!(
        json_data: { stripe_payment_intent_id: "pi_3SOdsrIBOqvOFDrf1VLLMqSi" },
        processor_payment_method_id: "pm_1SOdsoIBOqvOFDrfq67sVBc6",
        stripe_customer_id: "cus_TLKXDRZTbaggkA"
      )
      subscription = create_subscription(link: product, user: buyer, credit_card: indian_cc)
      create_membership_purchase(is_original_subscription_purchase: true, link: product, variant_attributes: [product.default_tier],
                                 price_cents: 5_00, subscription:, purchaser: buyer, credit_card: indian_cc)

      assert_changes -> { Purchase.count }, from: Purchase.count, to: Purchase.count + 1 do
        subscription.charge!
      end

      subscription.reload
      latest_purchase = Purchase.last
      assert_equal "failed", latest_purchase.purchase_state
      assert_equal "india_recurring_payment_mandate_canceled", latest_purchase.stripe_error_code
      assert_equal indian_cc, subscription.credit_card
      assert_equal latest_purchase.credit_card, subscription.credit_card
    end
  end

  test "#charge! uses the payment instrument attached to the subscription in case the purchaser account's saved payment instrument is not supported by this creator" do
    VCR.use_cassette("Subscription/_charge_/uses_the_payment_instrument_attached_to_the_subscription_in_case_the_purchaser_account_s_saved_payment_instrument_is_not_supported_by_this_creator") do
      charge_section_setup
      user = create_user
      native_paypal_card = CreditCard.create(build_native_paypal_chargeable, nil, user)
      user.credit_card = native_paypal_card
      user.save!

      discover_cc = CreditCard.create(build_chargeable(card: StripePaymentMethodHelper.success_discover), nil, user)
      subscription = nil
      travel_to(1.month.ago) do
        subscription = create_subscription(user:, link: @product, credit_card: discover_cc)
        create_purchase(is_original_subscription_purchase: true, link: @product, subscription:, credit_card: discover_cc)
      end

      assert_changes -> { Purchase.count }, from: Purchase.count, to: Purchase.count + 1 do
        subscription.charge!
      end

      subscription.reload
      assert_equal 2, subscription.purchases.count
      latest_purchase = subscription.purchases.last
      assert_equal "successful", latest_purchase.purchase_state
      assert_equal "**** **** **** 9424", latest_purchase.card_visual
      assert_equal discover_cc, subscription.credit_card
      assert_equal latest_purchase.credit_card, subscription.credit_card

      travel_to(1.month.from_now) do
        # Creator adds support for native paypal payments
        create_merchant_account_paypal(user: @product.user, charge_processor_merchant_id: "CJS32DZ7NDN5L", currency: "gbp")

        assert_changes -> { Purchase.count }, from: Purchase.count, to: Purchase.count + 1 do
          subscription.charge!
        end

        subscription.reload
        assert_equal 3, subscription.purchases.count
        latest_purchase = subscription.purchases.last
        assert_equal "successful", latest_purchase.purchase_state
        assert_equal discover_cc, latest_purchase.credit_card
      end
    end
  end

  test "#charge! transfers VAT ID and elected tax country from the original purchase to recurring charge" do
    VCR.use_cassette("Subscription/_charge_/transfers_VAT_ID_and_elected_tax_country_from_the_original_purchase_to_recurring_charge") do
      charge_section_setup
      create_zip_tax_rate(country: "IT", zip_code: nil, state: nil, combined_rate: 0.22, is_seller_responsible: false)

      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: @product)
      original_purchase = build_purchase(is_original_subscription_purchase: true, link: @product,
                                         subscription:, chargeable: build_chargeable, purchase_state: "in_progress",
                                         full_name: "gum stein", ip_address: "2.47.255.255", country: "Italy", created_at: 2.days.ago)
      original_purchase.business_vat_id = "IE6388047V"
      original_purchase.process!
      assert_equal 0, original_purchase.reload.gumroad_tax_cents

      subscription.charge!
      charge_purchase = subscription.reload.purchases.last
      assert_equal "successful", charge_purchase.purchase_state
      assert_equal "IE6388047V", charge_purchase.purchase_sales_tax_info.business_vat_id
      assert_equal original_purchase.total_transaction_cents, charge_purchase.total_transaction_cents
      assert_equal 0, charge_purchase.gumroad_tax_cents
    end
  end

  test "#charge! transfers VAT ID from the original purchase's tax refund to recurring charge" do
    VCR.use_cassette("Subscription/_charge_/transfers_VAT_ID_from_the_original_purchase_s_tax_refund_to_recurring_charge") do
      charge_section_setup
      create_zip_tax_rate(country: "IT", zip_code: nil, state: nil, combined_rate: 0.22, is_seller_responsible: false)

      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: @product)
      original_purchase = create_purchase(is_original_subscription_purchase: true, link: @product,
                                          subscription:, chargeable: build_chargeable, purchase_state: "in_progress",
                                          full_name: "gum stein", ip_address: "2.47.255.255", country: "Italy", created_at: 2.days.ago)
      original_purchase.process!(off_session: false)
      assert_equal 22, original_purchase.gumroad_tax_cents
      original_purchase.refund_gumroad_taxes!(refunding_user_id: @product.user.id, note: "Sample Note", business_vat_id: "IE6388047V")

      subscription.charge!
      charge_purchase = subscription.reload.purchases.last
      assert_equal "successful", charge_purchase.purchase_state
      assert_equal "IE6388047V", charge_purchase.purchase_sales_tax_info.business_vat_id
      assert_equal 0, charge_purchase.gumroad_tax_cents
    end
  end

  test "#charge! transfers VAT ID from subscription's stored business_vat_id to recurring charge" do
    VCR.use_cassette("Subscription/_charge_/transfers_VAT_ID_from_subscription_s_stored_business_vat_id_to_recurring_charge") do
      charge_section_setup
      create_zip_tax_rate(country: "IT", zip_code: nil, state: nil, combined_rate: 0.22, is_seller_responsible: false)

      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: @product, business_vat_id: "IE6388047V")
      original_purchase = create_purchase(is_original_subscription_purchase: true, link: @product,
                                          subscription:, chargeable: build_chargeable, purchase_state: "in_progress",
                                          full_name: "gum stein", ip_address: "2.47.255.255", country: "Italy", created_at: 2.days.ago)
      original_purchase.process!(off_session: false)
      assert_equal 22, original_purchase.gumroad_tax_cents

      subscription.charge!
      charge_purchase = subscription.reload.purchases.last
      assert_equal "successful", charge_purchase.purchase_state
      assert_equal "IE6388047V", charge_purchase.purchase_sales_tax_info.business_vat_id
      assert_equal 0, charge_purchase.gumroad_tax_cents
    end
  end

  test "#charge! transfers VAT ID from a recurring charge's VAT refund to subsequent recurring charges" do
    VCR.use_cassette("Subscription/_charge_/transfers_VAT_ID_from_a_recurring_charge_s_VAT_refund_to_subsequent_recurring_charges") do
      charge_section_setup
      create_zip_tax_rate(country: "IT", zip_code: nil, state: nil, combined_rate: 0.22, is_seller_responsible: false)

      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: @product)
      original_purchase = create_purchase(is_original_subscription_purchase: true, link: @product,
                                          subscription:, chargeable: build_chargeable, purchase_state: "in_progress",
                                          full_name: "gum stein", ip_address: "2.47.255.255", country: "Italy", created_at: 2.months.ago)

      travel_to(2.months.ago) do
        original_purchase.process!(off_session: false)
        assert_equal 22, original_purchase.gumroad_tax_cents
      end

      travel_to(1.month.ago) do
        first_recurring_purchase = subscription.charge!
        assert_equal "successful", first_recurring_purchase.purchase_state
        assert_equal 22, first_recurring_purchase.gumroad_tax_cents

        first_recurring_purchase.refund_gumroad_taxes!(refunding_user_id: @product.user.id, note: "Sample Note", business_vat_id: "IE6388047V")
        assert_equal "IE6388047V", subscription.reload.business_vat_id
      end

      second_recurring_purchase = subscription.charge!
      assert_equal "successful", second_recurring_purchase.purchase_state
      assert_equal "IE6388047V", second_recurring_purchase.purchase_sales_tax_info.business_vat_id
      assert_equal 0, second_recurring_purchase.gumroad_tax_cents
    end
  end

  # --- #charge! handling of unexpected errors --------------------------------

  test "#charge! handling of unexpected errors when a rate limit error occurs does not leave the purchase in in_progress state" do
    VCR.use_cassette("Subscription/_charge_/handling_of_unexpected_errors/when_a_rate_limit_error_occurs/does_not_leave_the_purchase_in_in_progress_state") do
      charge_section_setup
      Stripe::PaymentIntent.expects(:create).raises(Stripe::RateLimitError.new)
      assert_no_difference -> { Purchase.in_progress.count } do
        assert_difference -> { Purchase.failed.count }, 1 do
          assert_raises(ChargeProcessorError) { @subscription.charge! }
        end
      end
    end
  end

  test "#charge! handling of unexpected errors when a generic Stripeerror occurs does not leave the purchase in in_progress state" do
    VCR.use_cassette("Subscription/_charge_/handling_of_unexpected_errors/when_a_generic_Stripeerror_occurs/does_not_leave_the_purchase_in_in_progress_state") do
      charge_section_setup
      Stripe::PaymentIntent.expects(:create).raises(Stripe::IdempotencyError.new)
      assert_no_difference -> { Purchase.in_progress.count } do
        purchase = @subscription.charge!
        assert_equal "failed", purchase.purchase_state
      end
    end
  end

  test "#charge! handling of unexpected errors when a generic Braintree error occurs does not leave the purchase in in_progress state" do
    VCR.use_cassette("Subscription/_charge_/handling_of_unexpected_errors/when_a_generic_Braintree_error_occurs/does_not_leave_the_purchase_in_in_progress_state") do
      charge_section_setup
      MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id) ||
        MerchantAccount.create!(user: nil, charge_processor_id: BraintreeChargeProcessor.charge_processor_id,
                                charge_processor_merchant_id: "braintree_#{unique_suffix}")
      paypal_card = CreditCard.create(build_paypal_chargeable, nil, @subscription.user)
      @subscription.user.credit_card = paypal_card
      @subscription.user.save!

      Braintree::Transaction.expects(:sale).raises(Braintree::BraintreeError)
      assert_no_difference -> { Purchase.in_progress.count } do
        purchase = @subscription.charge!
        assert_equal "failed", purchase.purchase_state
      end
    end
  end

  test "#charge! handling of unexpected errors when a PayPal connection error occurs does not leave the purchase in in_progress state" do
    VCR.use_cassette("Subscription/_charge_/handling_of_unexpected_errors/when_a_PayPal_connection_error_occurs/does_not_leave_the_purchase_in_in_progress_state") do
      charge_section_setup
      native_paypal_card = CreditCard.create(build_native_paypal_chargeable, nil, @subscription.user)
      @subscription.user.credit_card = native_paypal_card
      @subscription.user.save!

      create_merchant_account_paypal(user: @subscription.link.user, charge_processor_merchant_id: "CJS32DZ7NDN5L", currency: "gbp")

      PayPal::PayPalHttpClient.any_instance.expects(:execute).raises(PayPalHttp::HttpError.new(418, OpenStruct.new(details: [OpenStruct.new(description: "IO Error")]), nil))
      assert_no_difference -> { Purchase.in_progress.count } do
        purchase = @subscription.charge!
        assert_equal "failed", purchase.purchase_state
      end
    end
  end

  test "#charge! handling of unexpected errors when unexpected runtime error occurs mid purchase does not leave the purchase in in_progress state" do
    VCR.use_cassette("Subscription/_charge_/handling_of_unexpected_errors/when_unexpected_runtime_error_occurs_mid_purchase/does_not_leave_the_purchase_in_in_progress_state") do
      charge_section_setup
      Purchase.any_instance.expects(:charge!).raises(RuntimeError)
      assert_no_difference -> { Purchase.in_progress.count } do
        assert_difference -> { Purchase.failed.count }, 1 do
          assert_raises(RuntimeError) { @subscription.charge! }
        end
      end
    end
  end

  # --- #charge! physical subscription ----------------------------------------

  def physical_subscription_context
    @physical_link = create_physical_product(user: create_user, is_recurring_billing: true, price_cents: 2500, subscription_duration: :monthly)
    @physical_link.shipping_destinations << ShippingDestination.new(country_code: "US", one_item_rate_cents: 1000, multiple_items_rate_cents: 500)
    @physical_link.save!
    @subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: @physical_link)
    @purchase = create_purchase(link: @physical_link, displayed_price_cents: @physical_link.price_cents, is_original_subscription_purchase: true,
                                subscription: @subscription, street_address: "1640 17th St", city: "San Francisco", state: "CA",
                                zip_code: "94107", country: "United States", full_name: "Anish Gumroad", shipping_cents: 1000,
                                created_at: 1.week.ago)
  end

  test "#charge! physical subscription charges the price of the subscription and shipping" do
    VCR.use_cassette("Subscription/_charge_/physical_subscription/charges_the_price_of_the_subscription_and_shipping") do
      physical_subscription_context
      assert_difference -> { Purchase.count }, 1 do
        @subscription.charge!
      end
      purchase = Purchase.last
      assert_equal "successful", purchase.purchase_state
      assert_equal @subscription, purchase.subscription
      assert_equal @physical_link, purchase.link
      assert_equal 1000, purchase.shipping_cents
      assert_equal 3500, purchase.total_transaction_cents
      assert_equal false, purchase.is_original_subscription_purchase
    end
  end

  test "#charge! physical subscription copies shipping information over to new purchase" do
    VCR.use_cassette("Subscription/_charge_/physical_subscription/copies_shipping_information_over_to_new_purchase") do
      physical_subscription_context
      assert_difference -> { Purchase.count }, 1 do
        @subscription.charge!
      end
      purchase = Purchase.last
      assert_equal "successful", purchase.purchase_state
      assert_equal @subscription, purchase.subscription
      assert_equal @physical_link, purchase.link
      assert_equal "1640 17th St", purchase.street_address
      assert_equal "San Francisco", purchase.city
      assert_equal "CA", purchase.state
      assert_equal "94107", purchase.zip_code
      assert_equal "United States", purchase.country
      assert_equal "Anish Gumroad", purchase.full_name
    end
  end

  test "#charge! physical subscription limited quantites does not reduce the number available" do
    VCR.use_cassette("Subscription/_charge_/physical_subscription/limited_quantites/does_not_reduce_the_number_available") do
      physical_subscription_context
      @physical_link.update(max_purchase_count: 5)
      assert_no_difference -> { @physical_link.reload.remaining_for_sale_count } do
        @subscription.charge!
      end
    end
  end

  test "#charge! physical subscription limited quantites multi quantity purchase charges the correct amounts" do
    VCR.use_cassette("Subscription/_charge_/physical_subscription/limited_quantites/multi_quantity_purchase/charges_the_correct_amounts") do
      physical_subscription_context
      @physical_link.update(max_purchase_count: 5)
      double_subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: @physical_link)
      create_purchase(link: @physical_link, displayed_price_cents: @physical_link.price_cents, is_original_subscription_purchase: true,
                      subscription: double_subscription, street_address: "1640 17th St", city: "San Francisco", state: "CA",
                      zip_code: "94107", country: "United States", full_name: "Anish Gumroad", quantity: 2, shipping_cents: 1500,
                      created_at: 1.week.ago)

      assert_difference -> { Purchase.count }, 1 do
        double_subscription.charge!
      end
      purchase = Purchase.last
      assert_equal "successful", purchase.purchase_state
      assert_equal double_subscription, purchase.subscription
      assert_equal @physical_link, purchase.link
      assert_equal 1500, purchase.shipping_cents
      assert_equal 4000, purchase.total_transaction_cents
      assert_equal 2, purchase.quantity
      assert_equal false, purchase.is_original_subscription_purchase
    end
  end

  test "#charge! physical subscription limited quantites multi quantity purchase does not reduce the number available" do
    VCR.use_cassette("Subscription/_charge_/physical_subscription/limited_quantites/multi_quantity_purchase/does_not_reduce_the_number_available") do
      physical_subscription_context
      @physical_link.update(max_purchase_count: 5)
      double_subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: @physical_link)
      create_purchase(link: @physical_link, displayed_price_cents: @physical_link.price_cents, is_original_subscription_purchase: true,
                      subscription: double_subscription, street_address: "1640 17th St", city: "San Francisco", state: "CA",
                      zip_code: "94107", country: "United States", full_name: "Anish Gumroad", quantity: 2, shipping_cents: 1500,
                      created_at: 1.week.ago)

      assert_no_difference -> { @physical_link.reload.remaining_for_sale_count } do
        double_subscription.charge!
      end
    end
  end

  # --- #charge! limited quantities -------------------------------------------

  test "#charge! limited quantities limited quantity does not reduce the number available" do
    VCR.use_cassette("Subscription/_charge_/limited_quantities/limited_quantity/does_not_reduce_the_number_available") do
      product = create_subscription_product(user: create_user, max_purchase_count: 10)
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      create_purchase(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true,
                      subscription:, created_at: 1.day.ago)
      assert_no_difference -> { product.reload.remaining_for_sale_count } do
        subscription.charge!
      end
    end
  end

  test "#charge! limited quantities changing variants allows the recurring charge to go through regardless of variant changes" do
    VCR.use_cassette("Subscription/_charge_/limited_quantities/changing_variants/allows_the_recurring_charge_to_go_through_regardless_of_variant_changes") do
      product = create_subscription_product(user: create_user)
      variant_category = create_variant_category(link: product, title: "colors")
      variant = create_variant(variant_category:, name: "orange")
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      create_purchase(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true,
                      subscription:, variant_attributes: [variant], created_at: 1.day.ago)

      new_variant_category = create_variant_category(link: product, title: "sizes")
      create_variant(variant_category: new_variant_category, name: "large")
      subscription.charge!
      assert_equal "successful", Purchase.last.purchase_state
    end
  end

  test "#charge! limited quantities limited variant quantity creates a new purchase row" do
    VCR.use_cassette("Subscription/_charge_/limited_quantities/limited_variant_quantity/creates_a_new_purchase_row") do
      product = create_subscription_product(user: create_user)
      variant_category = create_variant_category(link: product, title: "colors")
      variant = create_variant(variant_category:, name: "orange", max_purchase_count: 10)
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      create_purchase_with_balance(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true,
                                   subscription:, variant_attributes: [variant], created_at: 1.day.ago)
      assert_difference -> { Purchase.count }, 1 do
        subscription.charge!
      end
    end
  end

  test "#charge! limited quantities limited variant quantity does not reduce the amount available" do
    VCR.use_cassette("Subscription/_charge_/limited_quantities/limited_variant_quantity/does_not_reduce_the_amount_available") do
      product = create_subscription_product(user: create_user)
      variant_category = create_variant_category(link: product, title: "colors")
      variant = create_variant(variant_category:, name: "orange", max_purchase_count: 10)
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      create_purchase_with_balance(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true,
                                   subscription:, variant_attributes: [variant], created_at: 1.day.ago)
      assert_no_difference -> { variant.reload.quantity_left } do
        subscription.charge!
      end
    end
  end

  test "#charge! limited quantities limited variant quantity no variants left new purchase does not allow extra purchases to go through" do
    VCR.use_cassette("Subscription/_charge_/limited_quantities/limited_variant_quantity/no_variants_left/new_purchase/does_not_allow_extra_purchases_to_go_through") do
      product = create_membership_product(user: create_user)
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      variant_category = product.tier_category
      variant = create_variant(variant_category:, name: "2nd Tier", max_purchase_count: 1)
      create_purchase_with_balance(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true,
                                   subscription:, variant_attributes: [variant], created_at: 1.day.ago)

      purchase = create_purchase(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true,
                                 subscription:, variant_attributes: [variant], created_at: Time.current)
      assert_predicate purchase.errors[:base], :present?
      assert_equal PurchaseErrorCode::VARIANT_SOLD_OUT, purchase.error_code
    end
  end

  test "#charge! limited quantities limited variant quantity no variants left allows recurring charges to go through and create new purchase row" do
    VCR.use_cassette("Subscription/_charge_/limited_quantities/limited_variant_quantity/no_variants_left/allows_recurring_charges_to_go_through_and_create_new_purchase_row") do
      product = create_membership_product(user: create_user)
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      variant_category = product.tier_category
      variant = create_variant(variant_category:, name: "2nd Tier", max_purchase_count: 1)
      create_purchase_with_balance(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true,
                                   subscription:, variant_attributes: [variant], created_at: 1.day.ago)
      assert_difference -> { Purchase.count }, 1 do
        subscription.charge!
      end
    end
  end

  test "#charge! limited quantities limited variant quantity no variants left makes the new purchase row successful" do
    VCR.use_cassette("Subscription/_charge_/limited_quantities/limited_variant_quantity/no_variants_left/makes_the_new_purchase_row_successful") do
      product = create_membership_product(user: create_user)
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      variant_category = product.tier_category
      variant = create_variant(variant_category:, name: "2nd Tier", max_purchase_count: 1)
      create_purchase_with_balance(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true,
                                   subscription:, variant_attributes: [variant], created_at: 1.day.ago)
      subscription.charge!
      assert_equal "successful", Purchase.last.purchase_state
    end
  end

  test "#charge! limited quantities variable priced products sets the price of the purchase row correctly" do
    VCR.use_cassette("Subscription/_charge_/limited_quantities/variable_priced_products/sets_the_price_of_the_purchase_row_correctly") do
      product = create_subscription_product(user: create_user, customizable_price: true)
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      original_purchase = create_purchase(link: product, email: subscription.user.email, price_cents: 800,
                                          is_original_subscription_purchase: true, subscription:, created_at: 1.day.ago)
      purchase = subscription.charge!
      assert_equal subscription, purchase.subscription
      assert_equal product, purchase.link
      assert_equal original_purchase.email, purchase.email
      assert_equal original_purchase.ip_address, purchase.ip_address
      assert_equal original_purchase.browser_guid, purchase.browser_guid
      assert_equal false, purchase.is_original_subscription_purchase
      assert_equal 800, purchase.displayed_price_cents
      assert_equal 800, purchase.price_cents
    end
  end

  test "#charge! limited quantities limited offer code quantity offer codes still available creates a new purchase row" do
    VCR.use_cassette("Subscription/_charge_/limited_quantities/limited_offer_code_quantity/offer_codes_still_available/creates_a_new_purchase_row") do
      product = create_subscription_product(user: create_user)
      offer_code = create_offer_code(products: [product], code: "thanks9", max_purchase_count: 2)
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      create_purchase(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true,
                      subscription:, offer_code:, discount_code: offer_code.code, created_at: 1.day.ago)
      assert_difference -> { Purchase.count }, 1 do
        subscription.charge!
      end
    end
  end

  test "#charge! limited quantities limited offer code quantity offer codes still available does not reduce the amount available" do
    VCR.use_cassette("Subscription/_charge_/limited_quantities/limited_offer_code_quantity/offer_codes_still_available/does_not_reduce_the_amount_available") do
      product = create_subscription_product(user: create_user)
      offer_code = create_offer_code(products: [product], code: "thanks9", max_purchase_count: 2)
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      create_purchase(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true,
                      subscription:, offer_code:, discount_code: offer_code.code, created_at: 1.day.ago)
      still_valid = offer_code.reload.is_valid_for_purchase?
      subscription.charge!
      assert_equal still_valid, offer_code.reload.is_valid_for_purchase?
    end
  end

  test "#charge! limited quantities limited offer code quantity last offer code available does not allow extra purchases to go through" do
    VCR.use_cassette("Subscription/_charge_/limited_quantities/limited_offer_code_quantity/last_offer_code_available/does_not_allow_extra_purchases_to_go_through") do
      product = create_membership_product(user: create_user)
      variant = product.tiers.first
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      offer_code = create_offer_code(products: [product], max_purchase_count: 1, code: "thanks1")
      create_purchase(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true, subscription:,
                      offer_code:, discount_code: offer_code.code, variant_attributes: [variant], created_at: 1.day.ago)

      p = create_purchase(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true, subscription:,
                          offer_code:, discount_code: offer_code.code, variant_attributes: [variant], created_at: Time.current)
      assert_equal "offer_code_sold_out", p.error_code
    end
  end

  test "#charge! limited quantities limited offer code quantity last offer code available allows recurring charges to go through and create new purchase row" do
    VCR.use_cassette("Subscription/_charge_/limited_quantities/limited_offer_code_quantity/last_offer_code_available/allows_recurring_charges_to_go_through_and_create_new_purchase_row") do
      product = create_membership_product(user: create_user)
      variant = product.tiers.first
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      offer_code = create_offer_code(products: [product], max_purchase_count: 1, code: "thanks1")
      create_purchase(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true, subscription:,
                      offer_code:, discount_code: offer_code.code, variant_attributes: [variant], created_at: 1.day.ago)

      assert_equal 0, subscription.current_subscription_price_cents
      assert_difference -> { Purchase.count }, 1 do
        subscription.charge!
      end
    end
  end

  test "#charge! limited quantities limited offer code quantity last offer code available makes the new purchase row successful" do
    VCR.use_cassette("Subscription/_charge_/limited_quantities/limited_offer_code_quantity/last_offer_code_available/makes_the_new_purchase_row_successful") do
      product = create_membership_product(user: create_user)
      variant = product.tiers.first
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      offer_code = create_offer_code(products: [product], max_purchase_count: 1, code: "thanks1")
      create_purchase(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true, subscription:,
                      offer_code:, discount_code: offer_code.code, variant_attributes: [variant], created_at: 1.day.ago)
      subscription.charge!
      assert_equal "successful", Purchase.last.purchase_state
    end
  end
end
