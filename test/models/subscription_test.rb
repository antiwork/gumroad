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
  include CurrencyHelper # get_usd_cents/get_rate, used by the currency-conversion charge cases

  # Sidekiq runs in fake mode, so assert on the recorded jobs directly. `at:`
  # checks a scheduled (perform_in/perform_at) job's run time to the second.
  def assert_sidekiq_enqueued(worker, args:, at: nil)
    job = worker.jobs.find { |j| j["args"] == args }
    assert job, "expected #{worker} to be enqueued with #{args.inspect}"
    assert_in_delta at.to_f, job["at"], 1 if at
  end

  def refute_sidekiq_enqueued(worker, args:)
    assert worker.jobs.none? { |j| j["args"] == args }, "expected #{worker} not to be enqueued with #{args.inspect}"
  end

  # Mailers are delivered with deliver_later, which enqueues the app's
  # configured delivery job (MailDeliveryJob, a subclass of
  # ActionMailer::MailDeliveryJob — see config/application.rb); assert on the
  # enqueued job (mailer, method, and the method's args) rather than on
  # ActionMailer::Base.deliveries. Match by ancestry, not by exact class name,
  # so this helper keeps working if the delivery job class changes again.
  def mail_enqueued?(mailer, method, args:)
    enqueued_jobs.any? do |job|
      job[:job].respond_to?(:ancestors) && job[:job] <= ActionMailer::MailDeliveryJob &&
        job[:args][0] == mailer.name && job[:args][1] == method.to_s &&
        job[:args][3].is_a?(Hash) && job[:args][3]["args"] == args
    end
  end

  def assert_enqueued_email(mailer, method, args:)
    assert mail_enqueued?(mailer, method, args:), "expected #{mailer}##{method} enqueued with #{args.inspect}"
  end

  def refute_enqueued_email(mailer, method, args:)
    assert_not mail_enqueued?(mailer, method, args:), "expected #{mailer}##{method} not enqueued with #{args.inspect}"
  end

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

  # Ports ManageSubscriptionHelpers#shared_setup: a tiered membership with three
  # priced tiers across four recurrences, plus a subscriber with a saved card.
  # Reused by setup_subscription for the plan-change, price, and reminder cases.
  def shared_setup(originally_subscribed_at: nil, recommendable: false)
    @user = create_user
    @credit_card = create_credit_card(user: @user)
    @user.update!(credit_card: @credit_card)

    recurrence_price_values = [
      {
        BasePrice::Recurrence::MONTHLY => { enabled: true, price: 3 },
        BasePrice::Recurrence::QUARTERLY => { enabled: true, price: 5.99 },
        BasePrice::Recurrence::YEARLY => { enabled: true, price: 10 },
        BasePrice::Recurrence::EVERY_TWO_YEARS => { enabled: true, price: 18 },
      },
      {
        BasePrice::Recurrence::MONTHLY => { enabled: true, price: 5 },
        BasePrice::Recurrence::QUARTERLY => { enabled: true, price: 10.50 },
        BasePrice::Recurrence::YEARLY => { enabled: true, price: 20 },
        BasePrice::Recurrence::EVERY_TWO_YEARS => { enabled: true, price: 35 },
      },
      {
        BasePrice::Recurrence::MONTHLY => { enabled: true, price: 2.50 },
        BasePrice::Recurrence::QUARTERLY => { enabled: true, price: 4 },
        BasePrice::Recurrence::YEARLY => { enabled: true, price: 7.75 },
        BasePrice::Recurrence::EVERY_TWO_YEARS => { enabled: true, price: 15 },
      },
    ]
    @product = if recommendable
      create_recommendable_membership_product_with_preset_tiered_pricing(recurrence_price_values:)
    else
      create_membership_product_with_preset_tiered_pricing(recurrence_price_values:)
    end
    @monthly_product_price = @product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::MONTHLY)
    @quarterly_product_price = @product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::QUARTERLY)
    @yearly_product_price = @product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::YEARLY)
    @every_two_years_product_price = @product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS)

    @original_tier = @product.default_tier
    @original_tier_monthly_price = @original_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::MONTHLY)
    @original_tier_quarterly_price = @original_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::QUARTERLY)
    @original_tier_yearly_price = @original_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::YEARLY)
    @original_tier_every_two_years_price = @original_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS)

    @new_tier = @product.tiers.where.not(id: @original_tier.id).take!
    @new_tier_monthly_price = @new_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::MONTHLY)
    @new_tier_quarterly_price = @new_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::QUARTERLY)
    @new_tier_yearly_price = @new_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::YEARLY)
    @new_tier_every_two_years_price = @new_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS)

    @lower_tier = @product.tiers.where.not(id: [@original_tier.id, @new_tier.id]).take!
    @lower_tier_quarterly_price = @lower_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::QUARTERLY)

    @originally_subscribed_at = originally_subscribed_at || Time.utc(2020, 0o4, 0o1)

    @new_tier_yearly_upgrade_cost_after_one_month = 16_05
    @new_tier_quarterly_upgrade_cost_after_one_month = 6_55
    @original_tier_yearly_upgrade_cost_after_one_month = 6_05
  end

  # Ports ManageSubscriptionHelpers#setup_subscription: builds the shared tiered
  # membership and an original, processed subscription purchase on @original_tier.
  # The purchase is genuinely charged through Stripe, so callers wrap this in the
  # relevant VCR cassette.
  def setup_subscription(pwyw: false, with_product_files: false, originally_subscribed_at: nil, recurrence: BasePrice::Recurrence::QUARTERLY, free_trial: false, offer_code: nil, was_product_recommended: false, discover_fee_per_thousand: nil, is_multiseat_license: false, quantity: 1, gift: nil)
    shared_setup(recommendable: was_product_recommended)
    @product.update!(free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week) if free_trial
    @product.update!(discover_fee_per_thousand:) if discover_fee_per_thousand
    @product.update!(is_multiseat_license: quantity > 1 || is_multiseat_license)

    create_product_file(link: @product) if with_product_files

    @subscription = setup_original_subscription(
      product_price: @product.prices.alive.find_by!(recurrence:),
      tier: @original_tier,
      tier_price: @original_tier.prices.alive.find_by(recurrence:),
      pwyw:,
      with_product_files:,
      offer_code:,
      was_product_recommended:,
      quantity:,
      gift:
    )
    @original_purchase = @subscription.original_purchase
    @original_purchase.update!(gift_given: gift, is_gift_sender_purchase: true) if gift

    if is_multiseat_license
      create_license(purchase: @subscription.original_purchase)
      @product.update(is_licensed: true)
    end
  end

  # The subscription-building half of setup_subscription (the RSpec helper's inner
  # create_subscription, renamed to avoid clashing with the factory builder).
  def setup_original_subscription(product_price:, tier:, tier_price:, pwyw: false, with_product_files: false, offer_code: nil, was_product_recommended: false, quantity: 1, gift: nil)
    subscription = create_subscription(
      user: gift ? nil : @user,
      link: @product,
      price: product_price,
      credit_card: gift ? nil : @credit_card,
      free_trial_ends_at: @product.free_trial_enabled && !gift ? @originally_subscribed_at + @product.free_trial_duration : nil
    )

    travel_to(@originally_subscribed_at) do
      price = tier_price.price_cents
      price -= offer_code.amount_off(tier_price.price_cents) if offer_code.present?

      original_purchase = create_purchase(
        is_original_subscription_purchase: true,
        link: @product,
        subscription:,
        variant_attributes: [tier],
        price_cents: price * quantity,
        quantity:,
        credit_card: @credit_card,
        purchaser: @user,
        email: @user.email,
        is_free_trial_purchase: gift ? false : @product.free_trial_enabled?,
        offer_code:,
        purchase_state: "in_progress",
        was_product_recommended:
      )
      if pwyw
        tier.update!(customizable_price: true)
        original_purchase.perceived_price_cents = tier_price.price_cents + 1_00
      end

      create_recommended_purchase_info_via_discover(purchase: original_purchase, discover_fee_per_thousand: @product.discover_fee_per_thousand) if was_product_recommended

      original_purchase.process!
      original_purchase.update_balance_and_mark_successful!

      subscription.reload
      assert_equal(@product.free_trial_enabled? ? "not_charged" : "successful", original_purchase.purchase_state)
      if pwyw
        assert_equal price + 1_00, original_purchase.displayed_price_cents
      else
        assert_equal price * quantity, original_purchase.displayed_price_cents
      end
    end

    subscription
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
      # The RSpec original asserted against @end_of_month_cancelled — an unassigned
      # ivar (typo for @end_of_month_failed) that evaluated to nil, so the assertion
      # was trivially true. Assert against the real record so the test verifies that
      # installments published in the failure month are excluded.
      assert_not_includes @subscription.installments, @end_of_month_failed
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

      # Reload the sold-out variant: its inventory counter cache was bumped in
      # the database via update_all (see Purchase#sync_inventory_counter_caches_on_create),
      # so the in-memory instance is stale (inventory_counter_cache flag removal, gp#1208).
      purchase = create_purchase(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true,
                                 subscription:, variant_attributes: [variant.reload], created_at: Time.current)
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

  # --- #charge! discount with duration ---------------------------------------

  test "#charge! discount with duration tiered membership when the discount is no longer valid charges the full price" do
    VCR.use_cassette("Subscription/_charge_/discount_with_duration/tiered_membership/when_the_discount_is_no_longer_valid/charges_the_full_price") do
      user = create_user
      product = create_membership_product_with_preset_tiered_pricing(user:)
      offer_code = create_offer_code(products: [product])
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      purchase = create_purchase(link: product, email: subscription.user.email, full_name: "squiddy",
                                 price_cents: 200, is_original_subscription_purchase: true,
                                 subscription:, offer_code:,
                                 variant_attributes: [product.alive_variants.first], created_at: 2.days.ago)
      purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false, pre_discount_minimum_price_cents: 300, duration_in_billing_cycles: 1)

      subscription.charge!

      last = Purchase.last
      assert_nil last.offer_code
      assert_equal 300, last.displayed_price_cents
      assert_equal 300, last.price_cents
      assert_nil last.purchase_offer_code_discount
    end
  end

  test "#charge! discount with duration tiered membership when the discount is still valid charges the discounted price" do
    VCR.use_cassette("Subscription/_charge_/discount_with_duration/tiered_membership/when_the_discount_is_still_valid/charges_the_discounted_price") do
      user = create_user
      product = create_membership_product_with_preset_tiered_pricing(user:)
      offer_code = create_offer_code(products: [product])
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      purchase = create_purchase(link: product, email: subscription.user.email, full_name: "squiddy",
                                 price_cents: 200, is_original_subscription_purchase: true,
                                 subscription:, offer_code:,
                                 variant_attributes: [product.alive_variants.first], created_at: 2.days.ago)
      purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false, pre_discount_minimum_price_cents: 300, duration_in_billing_cycles: 1)
      subscription.original_purchase.purchase_offer_code_discount.update!(duration_in_billing_cycles: 2)

      subscription.charge!

      last = Purchase.last
      assert_equal 200, last.displayed_price_cents
      assert_equal 200, last.price_cents
      discount = last.purchase_offer_code_discount
      assert_equal offer_code, discount.offer_code
      assert_equal 100, discount.offer_code_amount
      assert_equal false, discount.offer_code_is_percent
    end
  end

  test "#charge! discount with duration legacy subscription when the discount is no longer valid charges the full price" do
    VCR.use_cassette("Subscription/_charge_/discount_with_duration/legacy_subscription/when_the_discount_is_no_longer_valid/charges_the_full_price") do
      user = create_user
      product = create_subscription_product(user:, price_cents: 300)
      offer_code = create_offer_code(products: [product], amount_cents: 100)
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      purchase = create_purchase(link: product, email: subscription.user.email, full_name: "squiddy",
                                 price_cents: 200, is_original_subscription_purchase: true,
                                 subscription:, offer_code:, created_at: 2.days.ago)
      purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false, pre_discount_minimum_price_cents: 300, duration_in_billing_cycles: 1)

      subscription.charge!

      last = Purchase.last
      assert_nil last.offer_code
      assert_equal 300, last.displayed_price_cents
      assert_equal 300, last.price_cents
      assert_nil last.purchase_offer_code_discount
    end
  end

  test "#charge! discount with duration legacy subscription when the discount is still valid charges the discounted price" do
    VCR.use_cassette("Subscription/_charge_/discount_with_duration/legacy_subscription/when_the_discount_is_still_valid/charges_the_discounted_price") do
      user = create_user
      product = create_subscription_product(user:, price_cents: 300)
      offer_code = create_offer_code(products: [product], amount_cents: 100)
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      purchase = create_purchase(link: product, email: subscription.user.email, full_name: "squiddy",
                                 price_cents: 200, is_original_subscription_purchase: true,
                                 subscription:, offer_code:, created_at: 2.days.ago)
      purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false, pre_discount_minimum_price_cents: 300, duration_in_billing_cycles: 1)
      subscription.original_purchase.purchase_offer_code_discount.update!(duration_in_billing_cycles: 2)

      subscription.charge!

      last = Purchase.last
      assert_equal 200, last.displayed_price_cents
      assert_equal 200, last.price_cents
      discount = last.purchase_offer_code_discount
      assert_equal offer_code, discount.offer_code
      assert_equal 100, discount.offer_code_amount
      assert_equal false, discount.offer_code_is_percent
    end
  end

  # --- #charge! yen ----------------------------------------------------------

  test "#charge! yen charges user at the same amount that they originally subscribed in" do
    VCR.use_cassette("Subscription/_charge_/yen/charges_user_at_the_same_amount_that_they_originally_subscribed_in") do
      product = create_subscription_product(user: create_user, price_currency_type: "jpy", price_cents: 400)
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      original_purchase = create_purchase(link: product, email: subscription.user.email, price_cents: get_usd_cents("jpy", product.price_cents),
                                          displayed_price_cents: product.price_cents, is_original_subscription_purchase: true, subscription:)

      Purchase.any_instance.stubs(:get_rate).with(:jpy).returns(90)
      travel_to(1.month.from_now) do
        purchase = subscription.charge!
        assert_equal subscription, purchase.subscription
        assert_equal product, purchase.link
        assert_equal original_purchase.email, purchase.email
        assert_equal original_purchase.ip_address, purchase.ip_address
        assert_equal original_purchase.browser_guid, purchase.browser_guid
        assert_equal false, purchase.is_original_subscription_purchase
        assert_equal original_purchase.displayed_price_cents, purchase.displayed_price_cents
        assert_not_equal original_purchase.price_cents, purchase.price_cents
      end
    end
  end

  # --- #charge! price changes ------------------------------------------------

  test "#charge! price changes charges the user the original amount" do
    VCR.use_cassette("Subscription/_charge_/price_changes/charges_the_user_the_original_amount") do
      product = create_subscription_product(user: create_user, price_cents: 400)
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      original_purchase = create_purchase(link: product, email: subscription.user.email, price_cents: product.price_cents,
                                          is_original_subscription_purchase: true, subscription:, created_at: Date.yesterday)

      product.update(price_cents: 500)

      purchase = subscription.charge!
      assert_equal subscription, purchase.subscription
      assert_equal product, purchase.link
      assert_equal original_purchase.email, purchase.email
      assert_equal original_purchase.ip_address, purchase.ip_address
      assert_equal original_purchase.browser_guid, purchase.browser_guid
      assert_equal false, purchase.is_original_subscription_purchase
      assert_equal original_purchase.displayed_price_cents, purchase.displayed_price_cents
      assert_equal original_purchase.price_cents, purchase.price_cents
      assert_equal "successful", purchase.purchase_state
    end
  end

  test "#charge! price changes with foreign currency charges the user the original amount in the foreign currency" do
    VCR.use_cassette("Subscription/_charge_/price_changes/with_foreign_currency/charges_the_user_the_original_amount_in_the_foreign_currency") do
      product = create_subscription_product(user: create_user, price_currency_type: "jpy", price_cents: 400)
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
      original_purchase = create_purchase(link: product, email: subscription.user.email, price_cents: get_usd_cents("jpy", product.price_cents),
                                          displayed_price_cents: product.price_cents, is_original_subscription_purchase: true,
                                          subscription:, created_at: Date.yesterday)

      product.update(price_cents: 500)
      Purchase.any_instance.stubs(:get_rate).with(:jpy).returns(50)

      purchase = subscription.charge!
      assert_equal subscription, purchase.subscription
      assert_equal product, purchase.link
      assert_equal original_purchase.email, purchase.email
      assert_equal original_purchase.ip_address, purchase.ip_address
      assert_equal original_purchase.browser_guid, purchase.browser_guid
      assert_equal false, purchase.is_original_subscription_purchase
      assert_equal original_purchase.displayed_price_cents, purchase.displayed_price_cents
      assert_equal 800, purchase.price_cents # 400 yen in usd cents based on the new rate
      assert_equal "successful", purchase.purchase_state
    end
  end

  # --- #charge! failure ------------------------------------------------------

  test "#charge! failure stripe unavailable does not send out email" do
    VCR.use_cassette("Subscription/_charge_/failure/stripe_unavailable/does_not_send_out_email") do
      charge_section_setup
      Stripe::PaymentIntent.stubs(:create).raises(Stripe::APIConnectionError)
      CustomerLowPriorityMailer.expects(:subscription_card_declined).never
      @subscription.charge!
    end
  end

  test "#charge! failure stripe unavailable does not schedule ChargeDeclinedReminderWorker" do
    VCR.use_cassette("Subscription/_charge_/failure/stripe_unavailable/does_not_schedule_ChargeDeclinedReminderWorker") do
      charge_section_setup
      Stripe::PaymentIntent.stubs(:create).raises(Stripe::APIConnectionError)
      @subscription.charge!
      refute_sidekiq_enqueued(ChargeDeclinedReminderWorker, args: [@subscription.id])
    end
  end

  test "#charge! failure stripe unavailable requeues RecurringCharge" do
    VCR.use_cassette("Subscription/_charge_/failure/stripe_unavailable/requeues_RecurringCharge") do
      charge_section_setup
      Stripe::PaymentIntent.stubs(:create).raises(Stripe::APIConnectionError)
      @subscription.charge!
      assert_sidekiq_enqueued(RecurringChargeWorker, args: [@subscription.id])
    end
  end

  test "#charge! failure stripe unavailable schedules the UnsubscribeAndFail job" do
    VCR.use_cassette("Subscription/_charge_/failure/stripe_unavailable/schedules_the_UnsubscribeAndFail_job") do
      charge_section_setup
      Stripe::PaymentIntent.stubs(:create).raises(Stripe::APIConnectionError)
      @subscription.charge!
      assert_sidekiq_enqueued(UnsubscribeAndFailWorker, args: [@subscription.id])
    end
  end

  test "#charge! failure from card declined email does not send out email" do
    VCR.use_cassette("Subscription/_charge_/failure/from_card_declined_email/does_not_send_out_email") do
      charge_section_setup
      CustomerLowPriorityMailer.expects(:subscription_card_declined).never
      @subscription.charge!(from_failed_charge_email: true)
    end
  end

  test "#charge! failure from card declined email does not schedule ChargeDeclinedReminderWorker" do
    VCR.use_cassette("Subscription/_charge_/failure/from_card_declined_email/does_not_schedule_ChargeDeclinedReminderWorker") do
      freeze_time do
        charge_section_setup
        @subscription.charge!(from_failed_charge_email: true)
        refute_sidekiq_enqueued(ChargeDeclinedReminderWorker, args: [@subscription.id])
      end
    end
  end

  test "#charge! failure from card declined email schedules the UnsubscribeAndFail job" do
    VCR.use_cassette("Subscription/_charge_/failure/from_card_declined_email/schedules_the_UnsubscribeAndFail_job") do
      freeze_time do
        charge_section_setup
        ChargeProcessor.stubs(:create_payment_intent_or_charge!).raises(ChargeProcessorCardError.new("card_declined"))
        @subscription.charge!(from_failed_charge_email: true)
        assert_sidekiq_enqueued(UnsubscribeAndFailWorker, args: [@subscription.id])
      end
    end
  end

  test "#charge! failure from card declined email does not requeue 1 hour job" do
    VCR.use_cassette("Subscription/_charge_/failure/from_card_declined_email/does_not_requeue_1_hour_job") do
      freeze_time do
        charge_section_setup
        ChargeProcessor.stubs(:create_payment_intent_or_charge!).raises(ChargeProcessorUnavailableError.new)
        @subscription.charge!(from_failed_charge_email: true)
        refute_sidekiq_enqueued(RecurringChargeWorker, args: [@subscription.id])
      end
    end
  end

  test "#charge! failure user removed credit card sends charge declined emails" do
    VCR.use_cassette("Subscription/_charge_/failure/user_removed_credit_card/sends_charge_declined_emails") do
      charge_section_setup
      @subscription.user.update!(credit_card_id: nil)
      mail = mock
      mail.stubs(:deliver_later)
      CustomerLowPriorityMailer.expects(:subscription_card_declined).returns(mail)
      @subscription.charge!
    end
  end

  test "#charge! failure user removed credit card schedules the UnsubscribeAndFail job" do
    VCR.use_cassette("Subscription/_charge_/failure/user_removed_credit_card/schedules_the_UnsubscribeAndFail_job") do
      charge_section_setup
      @subscription.user.update!(credit_card_id: nil)
      @subscription.charge!
      assert_sidekiq_enqueued(UnsubscribeAndFailWorker, args: [@subscription.id])
    end
  end

  test "#charge! failure when there are no successful, non-refunded or reversed purchases schedules the UnsubscribeAndFail job" do
    VCR.use_cassette("Subscription/_charge_/failure/when_there_are_no_successful_non-refunded_or_reversed_purchases/schedules_the_UnsubscribeAndFail_job") do
      charge_section_setup
      @subscription.original_purchase.update!(chargeback_date: 1.day.ago)
      Stripe::PaymentIntent.stubs(:create).raises(Stripe::APIConnectionError)

      @subscription.charge!
      assert_sidekiq_enqueued(UnsubscribeAndFailWorker, args: [@subscription.id])
    end
  end

  # --- #charge! double charged -----------------------------------------------

  test "#charge! double charged does not create the purchase row" do
    VCR.use_cassette("Subscription/_charge_/double_charged/does_not_create_the_purchase_row") do
      charge_section_setup
      create_purchase(link: @product, ip_address: @purchase.ip_address, email: @purchase.email, created_at: Time.current)
      assert_raises(StateMachines::InvalidTransition) do
        @subscription.charge!
      end
    end
  end

  # --- #charge! card error ---------------------------------------------------

  test "#charge! card error card_declined sends the correct email" do
    VCR.use_cassette("Subscription/_charge_/card_error/card_declined/sends_the_correct_email") do
      charge_section_setup
      ChargeProcessor.stubs(:create_payment_intent_or_charge!).raises(ChargeProcessorCardError.new("card_declined"))
      mail = mock
      mail.stubs(:deliver_later)
      CustomerLowPriorityMailer.expects(:subscription_card_declined).returns(mail)
      @subscription.charge!
    end
  end

  test "#charge! card error card_declined schedules ChargeDeclinedReminderWorker" do
    VCR.use_cassette("Subscription/_charge_/card_error/card_declined/schedules_ChargeDeclinedReminderWorker") do
      freeze_time do
        charge_section_setup
        ChargeProcessor.stubs(:create_payment_intent_or_charge!).raises(ChargeProcessorCardError.new("card_declined"))
        @subscription.charge!
        assert_sidekiq_enqueued(ChargeDeclinedReminderWorker, args: [@subscription.id], at: 3.days.from_now)
      end
    end
  end

  test "#charge! card error card_declined schedules the UnsubscribeAndFail job" do
    VCR.use_cassette("Subscription/_charge_/card_error/card_declined/schedules_the_UnsubscribeAndFail_job") do
      charge_section_setup
      ChargeProcessor.stubs(:create_payment_intent_or_charge!).raises(ChargeProcessorCardError.new("card_declined"))
      @subscription.charge!
      assert_sidekiq_enqueued(UnsubscribeAndFailWorker, args: [@subscription.id])
    end
  end

  test "#charge! card error card_declined invalid_cvc sends the correct email" do
    VCR.use_cassette("Subscription/_charge_/card_error/card_declined/invalid_cvc/sends_the_correct_email") do
      charge_section_setup
      ChargeProcessor.stubs(:create_payment_intent_or_charge!).raises(ChargeProcessorCardError.new("invalid_cvc"))
      mail = mock
      mail.stubs(:deliver_later)
      CustomerLowPriorityMailer.expects(:subscription_card_declined).returns(mail)
      @subscription.charge!
    end
  end

  test "#charge! card error card_declined invalid_cvc schedules ChargeDeclinedReminderWorker" do
    VCR.use_cassette("Subscription/_charge_/card_error/card_declined/invalid_cvc/schedules_ChargeDeclinedReminderWorker") do
      freeze_time do
        charge_section_setup
        ChargeProcessor.stubs(:create_payment_intent_or_charge!).raises(ChargeProcessorCardError.new("invalid_cvc"))
        @subscription.charge!
        assert_sidekiq_enqueued(ChargeDeclinedReminderWorker, args: [@subscription.id])
      end
    end
  end

  test "#charge! card error card_declined invalid_cvc requeues UnsubscribeAndFail" do
    VCR.use_cassette("Subscription/_charge_/card_error/card_declined/invalid_cvc/requeues_UnsubscribeAndFail") do
      freeze_time do
        charge_section_setup
        ChargeProcessor.stubs(:create_payment_intent_or_charge!).raises(ChargeProcessorCardError.new("invalid_cvc"))
        @subscription.charge!
        assert_sidekiq_enqueued(UnsubscribeAndFailWorker, args: [@subscription.id])
      end
    end
  end

  test "#charge! card error card_declined_insufficient_funds emails the subscriber" do
    VCR.use_cassette("Subscription/_charge_/card_error/card_declined_insufficient_funds/emails_the_subscriber") do
      charge_section_setup
      ChargeProcessor.stubs(:create_payment_intent_or_charge!).raises(ChargeProcessorCardError.new("card_declined_insufficient_funds"))
      mail = mock
      mail.stubs(:deliver_later)
      CustomerLowPriorityMailer.expects(:subscription_card_declined).returns(mail)
      @subscription.charge!
    end
  end

  test "#charge! card error card_declined_insufficient_funds schedules a ChargeDeclinedReminderWorker" do
    VCR.use_cassette("Subscription/_charge_/card_error/card_declined_insufficient_funds/schedules_a_ChargeDeclinedReminderWorker") do
      charge_section_setup
      ChargeProcessor.stubs(:create_payment_intent_or_charge!).raises(ChargeProcessorCardError.new("card_declined_insufficient_funds"))
      @subscription.charge!
      assert_sidekiq_enqueued(ChargeDeclinedReminderWorker, args: [@subscription.id])
    end
  end

  test "#charge! card error card_declined_insufficient_funds requeues RecurringCharge" do
    VCR.use_cassette("Subscription/_charge_/card_error/card_declined_insufficient_funds/requeues_RecurringCharge") do
      freeze_time do
        charge_section_setup
        ChargeProcessor.stubs(:create_payment_intent_or_charge!).raises(ChargeProcessorCardError.new("card_declined_insufficient_funds"))
        @subscription.charge!
        assert_sidekiq_enqueued(RecurringChargeWorker, args: [@subscription.id], at: 1.day.from_now)
      end
    end
  end

  test "#charge! card error card_declined_insufficient_funds schedules the UnsubscribeAndFail job" do
    VCR.use_cassette("Subscription/_charge_/card_error/card_declined_insufficient_funds/schedules_the_UnsubscribeAndFail_job") do
      charge_section_setup
      ChargeProcessor.stubs(:create_payment_intent_or_charge!).raises(ChargeProcessorCardError.new("card_declined_insufficient_funds"))
      @subscription.charge!
      assert_sidekiq_enqueued(UnsubscribeAndFailWorker, args: [@subscription.id])
    end
  end

  # --- #charge! affiliates ---------------------------------------------------

  test "#charge! affiliates associates the recurring charges to the same affiliate" do
    VCR.use_cassette("Subscription/_charge_/affiliates/associates_the_recurring_charges_to_the_same_affiliate") do
      charge_section_setup
      @product.update!(price_cents: 10_00)
      affiliate_user = create_affiliate_user
      direct_affiliate = create_direct_affiliate(affiliate_user:, seller: @product.user, affiliate_basis_points: 1000, products: [@product])
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: @product)
      purchase = create_purchase_in_progress(link: @product, email: subscription.user.email, full_name: "squiddy",
                                             price_cents: @product.price_cents, is_original_subscription_purchase: true,
                                             subscription:, created_at: 2.days.ago, affiliate: direct_affiliate)
      purchase.process!
      purchase.update_balance_and_mark_successful!
      recurring_purchase = subscription.charge!
      assert_equal "successful", recurring_purchase.purchase_state
      assert_equal 79, recurring_purchase.affiliate_credit_cents
      assert_equal direct_affiliate, recurring_purchase.affiliate
      assert_equal direct_affiliate, recurring_purchase.affiliate_credit.affiliate
      assert_equal 712 * 2, @product.user.unpaid_balance_cents # original subs purchase and the recurring purchase
      assert_equal 79 * 2, affiliate_user.unpaid_balance_cents
    end
  end

  test "#charge! affiliates does not associate the recurring charge to the affiliate if affiliate is using a Brazilian Stripe Connect account" do
    VCR.use_cassette("Subscription/_charge_/affiliates/does_not_associate_the_recurring_charge_to_the_affiliate_if_affiliate_is_using_a_Brazilian_Stripe_Connect_account") do
      charge_section_setup
      @product.update!(price_cents: 10_00)
      affiliate_user = create_affiliate_user
      direct_affiliate = create_direct_affiliate(affiliate_user:, seller: @product.user, affiliate_basis_points: 1000, products: [@product])
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: @product)
      purchase = create_purchase_in_progress(link: @product, email: subscription.user.email, full_name: "squiddy",
                                             price_cents: @product.price_cents, is_original_subscription_purchase: true,
                                             subscription:, created_at: 2.days.ago, affiliate: direct_affiliate)
      purchase.process!
      purchase.update_balance_and_mark_successful!
      assert_equal 79, purchase.affiliate_credit_cents
      assert_equal direct_affiliate, purchase.affiliate
      assert_equal direct_affiliate, purchase.affiliate_credit.affiliate
      assert_equal 712, @product.user.reload.unpaid_balance_cents # original subscription purchase
      assert_equal 79, affiliate_user.reload.unpaid_balance_cents

      brazilian_stripe_account = create_merchant_account_stripe_connect(user: affiliate_user, country: "BR")
      affiliate_user.update!(check_merchant_account_is_linked: true)
      assert_equal brazilian_stripe_account, affiliate_user.merchant_account(StripeChargeProcessor.charge_processor_id)

      recurring_purchase = subscription.charge!
      assert_equal "successful", recurring_purchase.purchase_state
      assert_equal 0, recurring_purchase.affiliate_credit_cents
      assert_nil recurring_purchase.affiliate
      assert_nil recurring_purchase.affiliate_credit
      assert_equal 712 + 791, @product.user.reload.unpaid_balance_cents # original subscription purchase and the recurring purchase
      assert_equal 79, affiliate_user.reload.unpaid_balance_cents
    end
  end

  # --- #charge! recommended --------------------------------------------------

  test "#charge! recommended shows the recurring charges as recommended, charge the extra fee, and create a new recommended_purchase_info" do
    VCR.use_cassette("Subscription/_charge_/recommended/shows_the_recurring_charges_as_recommended_charge_the_extra_fee_and_create_a_new_recommended_purchase_info") do
      charge_section_setup
      Link.any_instance.stubs(:recommendable?).returns(true)
      @product.update!(price_cents: 10_00)
      subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: @product)
      purchase = create_purchase_in_progress(link: @product, email: subscription.user.email, full_name: "squiddy",
                                             price_cents: @product.price_cents, is_original_subscription_purchase: true,
                                             subscription:, created_at: 2.days.ago, was_product_recommended: true)
      purchase.process!
      purchase.update_balance_and_mark_successful!
      recurring_purchase = subscription.charge!
      assert_equal "successful", recurring_purchase.purchase_state
      assert_equal 209, recurring_purchase.fee_cents # 100c (10% flat fee) + 50c + 29c (2.9% cc fee) + 30c (fixed cc fee)
      assert_equal true, recurring_purchase.was_product_recommended
      assert_predicate recurring_purchase.recommended_purchase_info, :present?
      assert_equal true, recurring_purchase.recommended_purchase_info.is_recurring_purchase
      assert_equal 100, recurring_purchase.recommended_purchase_info.discover_fee_per_thousand
      assert_equal 791 + 700, @product.user.unpaid_balance_cents # original subs purchase and the recurring purchase
    end
  end

  test "#charge! recommended discover fee charges the discover fee percentage from the original purchase instead of the current product discover fee" do
    VCR.use_cassette("Subscription/_charge_/recommended/discover_fee/charges_the_discover_fee_percentage_from_the_original_purchase_instead_of_the_current_product_discover_fee") do
      setup_subscription(was_product_recommended: true, discover_fee_per_thousand: 300)
      @product.update!(discover_fee_per_thousand: 400)
      Subscription.any_instance.stubs(:mor_fee_applicable?).returns(false)

      travel_to(1.day.from_now) { @subscription.charge! }

      recurring_purchase = @subscription.purchases.last
      assert_equal 300, recurring_purchase.discover_fee_per_thousand
      assert_equal 227, recurring_purchase.fee_cents # 599*0.329 + 30c
    end
  end

  test "#charge! recommended free trials charges the discover fee percentage from the original free trial purchase instead of the current product discover fee" do
    VCR.use_cassette("Subscription/_charge_/recommended/free_trials/charges_the_discover_fee_percentage_from_the_original_free_trial_purchase_instead_of_the_current_product_discover_fee") do
      setup_subscription(free_trial: true, was_product_recommended: true, discover_fee_per_thousand: 300)
      @product.update!(discover_fee_per_thousand: 100)
      Subscription.any_instance.stubs(:mor_fee_applicable?).returns(false)

      travel_to(1.day.from_now) { @subscription.charge! }

      recurring_purchase = @subscription.purchases.last
      assert_equal 300, recurring_purchase.discover_fee_per_thousand
      assert_equal 227, recurring_purchase.fee_cents # 599*0.329 + 30c
    end
  end

  # --- #charge! free trial ratings -------------------------------------------

  test "#charge! free trial ratings allows free trial subscriptions' ratings to be counted on successful charge" do
    VCR.use_cassette("Subscription/_charge_/free_trial_ratings/allows_free_trial_subscriptions_ratings_to_be_counted_on_successful_charge") do
      charge_section_setup
      purchase = create_free_trial_membership_purchase
      assert_equal true, purchase.should_exclude_product_review?

      purchase.subscription.charge!

      assert_equal false, purchase.reload.should_exclude_product_review?
    end
  end

  # --- #schedule_charge ------------------------------------------------------

  test "#schedule_charge schedules RecurringCharge at the specified time" do
    freeze_time do
      scheduled_time = Time.current + 1.day
      @subscription.schedule_charge(scheduled_time)
      assert_sidekiq_enqueued(RecurringChargeWorker, args: [@subscription.id], at: scheduled_time)
    end
  end

  test "#schedule_charge logs the scheduling operation" do
    freeze_time do
      scheduled_time = Time.current + 1.day
      log_text = "Scheduled RecurringChargeWorker(#{@subscription.id}) to run at #{scheduled_time}"
      Rails.logger.expects(:info).with(log_text)
      @subscription.schedule_charge(scheduled_time)
    end
  end

  # --- #unsubscribe_and_fail! ------------------------------------------------

  test "#unsubscribe_and_fail! unsubscribes the user" do
    assert_nil @subscription.failed_at
    assert_nil @subscription.deactivated_at
    @subscription.unsubscribe_and_fail!
    assert_not_nil @subscription.failed_at
    assert_not_nil @subscription.deactivated_at
  end

  test "#unsubscribe_and_fail! does not set cancelled_by_buyer" do
    assert_equal false, @subscription.cancelled_by_buyer
    @subscription.unsubscribe_and_fail!
    assert_equal false, @subscription.cancelled_by_buyer
  end

  test "#unsubscribe_and_fail! emails the creator when payment notifications are ON" do
    assert @subscription.seller.enable_payment_email
    @subscription.unsubscribe_and_fail!
    assert_enqueued_email(ContactingCreatorMailer, :subscription_autocancelled, args: [@subscription.id])
  end

  test "#unsubscribe_and_fail! does not email the creator when payment notifications are OFF" do
    @subscription.seller.update!(enable_payment_email: false)
    @subscription.unsubscribe_and_fail!
    refute_enqueued_email(ContactingCreatorMailer, :subscription_autocancelled, args: [@subscription.id])
  end

  test "#unsubscribe_and_fail! sends email to customer but not creator on repeated recent failure" do
    create_failed_purchase(link: @subscription.link, subscription: @subscription, email: @subscription.user.email, created_at: 2.hours.ago)
    assert_equal true, @subscription.seller.enable_payment_email
    @subscription.unsubscribe_and_fail!
    assert_enqueued_email(CustomerLowPriorityMailer, :subscription_autocancelled, args: [@subscription.id])
    refute_enqueued_email(ContactingCreatorMailer, :subscription_autocancelled, args: [@subscription.id])
  end

  test "#unsubscribe_and_fail! sends email to customer and creator on new failure more than 7 days ago" do
    create_failed_purchase(link: @subscription.link, subscription: @subscription, email: @subscription.user.email, created_at: 30.days.ago)
    assert_equal true, @subscription.seller.enable_payment_email
    @subscription.unsubscribe_and_fail!
    assert_enqueued_email(CustomerLowPriorityMailer, :subscription_autocancelled, args: [@subscription.id])
    assert_enqueued_email(ContactingCreatorMailer, :subscription_autocancelled, args: [@subscription.id])
  end

  test "#unsubscribe_and_fail! emails the customer" do
    @subscription.unsubscribe_and_fail!
    assert_enqueued_email(CustomerLowPriorityMailer, :subscription_autocancelled, args: [@subscription.id])
  end

  test "#unsubscribe_and_fail! enqueues the ping job to notify seller of subscription cancellation" do
    @subscription.unsubscribe_and_fail!
    assert_sidekiq_enqueued(PostToPingEndpointsWorker, args: [nil, nil, ResourceSubscription::CANCELLED_RESOURCE_NAME, @subscription.id])
  end

  test "#unsubscribe_and_fail! enqueues the ping job to notify seller of subscription ending" do
    @subscription.unsubscribe_and_fail!
    assert_sidekiq_enqueued(PostToPingEndpointsWorker, args: [nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, @subscription.id])
  end

  # --- #end_subscription! ----------------------------------------------------

  test "#end_subscription! ends the subscription" do
    @subscription.end_subscription!
    assert_not_nil @subscription.ended_at
    assert_not_nil @subscription.deactivated_at
  end

  test "#end_subscription! emails the customer" do
    @subscription.end_subscription!
    assert_enqueued_email(CustomerLowPriorityMailer, :subscription_ended, args: [@subscription.id])
  end

  test "#end_subscription! emails the creator when payment notifications are ON" do
    assert @subscription.seller.enable_payment_email
    @subscription.end_subscription!
    assert_enqueued_email(ContactingCreatorMailer, :subscription_ended, args: [@subscription.id])
  end

  test "#end_subscription! does not email the creator when payment notifications are OFF" do
    @subscription.seller.update!(enable_payment_email: false)
    @subscription.end_subscription!
    refute_enqueued_email(ContactingCreatorMailer, :subscription_ended, args: [@subscription.id])
  end

  test "#end_subscription! enqueues the ping job to notify seller of subscription ending" do
    @subscription.end_subscription!
    assert_sidekiq_enqueued(PostToPingEndpointsWorker, args: [nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, @subscription.id])
  end

  # --- #cancel! --------------------------------------------------------------

  test "#cancel! by_seller=false sets cancelled_at and user_requested_cancellation" do
    freeze_time do
      assert_changes -> { @subscription.reload.user_requested_cancellation_at.try(:utc).try(:to_i) }, from: nil, to: Time.current.to_i do
        @subscription.cancel!(by_seller: false)
      end
    end
  end

  test "#cancel! by_seller=false sets cancelled_by_buyer correctly" do
    assert_equal false, @subscription.cancelled_by_buyer
    @subscription.cancel!(by_seller: false)
    assert_equal true, @subscription.cancelled_by_buyer
  end

  test "#cancel! by_seller=false emails the buyer" do
    @subscription.cancel!(by_seller: false)
    assert_enqueued_email(CustomerLowPriorityMailer, :subscription_cancelled, args: [@subscription.id])
  end

  test "#cancel! by_seller=false emails the creator when payment notifications are ON" do
    assert @subscription.seller.enable_payment_email
    @subscription.cancel!(by_seller: false)
    assert_enqueued_email(ContactingCreatorMailer, :subscription_cancelled_by_customer, args: [@subscription.id])
  end

  test "#cancel! by_seller=false does not email the creator when payment notifications are OFF" do
    @subscription.seller.update!(enable_payment_email: false)
    @subscription.cancel!(by_seller: false)
    refute_enqueued_email(ContactingCreatorMailer, :subscription_cancelled_by_customer, args: [@subscription.id])
  end

  test "#cancel! by_seller=false enqueues the ping job to notify seller of subscription cancellation" do
    @subscription.cancel!(by_seller: false)
    assert_sidekiq_enqueued(PostToPingEndpointsWorker, args: [nil, nil, ResourceSubscription::CANCELLED_RESOURCE_NAME, @subscription.id])
  end

  test "#cancel! by_seller=true sets cancelled_at and user_requested_cancellation" do
    freeze_time do
      assert_changes -> { @subscription.reload.user_requested_cancellation_at.try(:utc).try(:to_i) }, from: nil, to: Time.current.to_i do
        @subscription.cancel!(by_seller: true)
      end
    end
  end

  test "#cancel! by_seller=true sets cancelled_by_buyer correctly" do
    assert_equal false, @subscription.cancelled_by_buyer
    @subscription.cancel!(by_seller: true)
    assert_equal false, @subscription.cancelled_by_buyer
  end

  test "#cancel! by_seller=true emails the buyer" do
    @subscription.cancel!(by_seller: true)
    assert_enqueued_email(CustomerLowPriorityMailer, :subscription_cancelled_by_seller, args: [@subscription.id])
  end

  test "#cancel! by_seller=true emails the creator when payment notifications are ON" do
    assert @subscription.seller.enable_payment_email
    @subscription.cancel!(by_seller: true)
    assert_enqueued_email(ContactingCreatorMailer, :subscription_cancelled, args: [@subscription.id])
  end

  test "#cancel! by_seller=true does not email the creator when payment notifications are OFF" do
    @subscription.seller.update!(enable_payment_email: false)
    @subscription.cancel!(by_seller: true)
    refute_enqueued_email(ContactingCreatorMailer, :subscription_cancelled, args: [@subscription.id])
  end

  test "#cancel! by_seller=true enqueues the ping job to notify seller of subscription cancellation" do
    @subscription.cancel!(by_seller: true)
    assert_sidekiq_enqueued(PostToPingEndpointsWorker, args: [nil, nil, ResourceSubscription::CANCELLED_RESOURCE_NAME, @subscription.id])
  end

  test "#cancel! by_admin=true sets the cancelled_by_admin correctly" do
    assert_equal false, @subscription.cancelled_by_admin
    @subscription.cancel!(by_admin: true)
    assert_equal true, @subscription.cancelled_by_admin
  end

  test "#cancel! by_admin=true emails the buyer" do
    mail = mock
    mail.stubs(:deliver_later)
    CustomerLowPriorityMailer.expects(:subscription_cancelled_by_seller).with(@subscription.id).returns(mail)
    @subscription.cancel!(by_admin: true)
  end

  test "#cancel! by_admin=true emails the creator when payment notifications are ON" do
    assert @subscription.seller.enable_payment_email
    @subscription.cancel!(by_admin: true)
    assert_enqueued_email(ContactingCreatorMailer, :subscription_cancelled, args: [@subscription.id])
  end

  test "#cancel! by_admin=true does not email the creator when payment notifications are OFF" do
    @subscription.seller.update!(enable_payment_email: false)
    @subscription.cancel!(by_admin: true)
    refute_enqueued_email(ContactingCreatorMailer, :subscription_cancelled, args: [@subscription.id])
  end

  test "#cancel! installment plans cannot be cancelled by the buyer" do
    purchase = create_installment_plan_purchase
    subscription = purchase.subscription
    error = assert_raises(ActiveRecord::RecordInvalid) { subscription.cancel!(by_seller: false) }
    assert_equal "Validation failed: Installment plans cannot be cancelled by the customer", error.message
  end

  test "#cancel! installment plans can be cancelled by the seller" do
    purchase = create_installment_plan_purchase
    subscription = purchase.subscription
    assert_changes -> { subscription.reload.cancelled_at }, from: nil do
      subscription.cancel!(by_seller: true)
    end
  end

  # --- #deactivate! ----------------------------------------------------------

  def deactivate_context
    @creator = create_user
    @product = create_subscription_product(user: @creator)
    @subscription = create_subscription(link: @product, cancelled_at: 2.days.ago)
    @sale = create_purchase(is_original_subscription_purchase: true, link: @product, subscription: @subscription, email: "test@example.com", created_at: 1.week.ago, price_cents: 100)
  end

  test "#deactivate! sets deactivated_at" do
    deactivate_context
    @subscription.deactivate!
    assert_predicate @subscription.reload.deactivated_at, :present?
  end

  test "#deactivate! enqueues deactivate integrations worker" do
    deactivate_context
    @subscription.deactivate!
    assert_sidekiq_enqueued(DeactivateIntegrationsWorker, args: [@subscription.original_purchase.id])
  end

  test "#deactivate! creates a subscription_event of type deactivated" do
    deactivate_context
    @subscription.deactivate!
    assert_equal "deactivated", @subscription.subscription_events.last.event_type
  end

  test "#deactivate! schedules a member cancellation installment for a creator's seller workflow" do
    deactivate_context
    workflow = create_seller_workflow(seller: @creator, workflow_trigger: "member_cancellation")
    installment = create_published_installment(workflow:, workflow_trigger: "member_cancellation")
    installment_rule = create_installment_rule(installment:, delayed_delivery_time: 1.day)

    @subscription.deactivate!
    @subscription.reload

    assert_sidekiq_enqueued(SendWorkflowInstallmentWorker,
                            args: [installment.id, installment_rule.version, nil, nil, nil, @subscription.id])
    job = SendWorkflowInstallmentWorker.jobs.find { |j| j["args"] == [installment.id, installment_rule.version, nil, nil, nil, @subscription.id] }
    assert_in_delta((@subscription.deactivated_at + installment_rule.delayed_delivery_time).to_f, job["at"], 1)
  end

  test "#deactivate! schedules a member cancellation installment for a creator's product workflow" do
    deactivate_context
    workflow = create_workflow(seller: @creator, link: @product, workflow_trigger: "member_cancellation")
    installment = create_published_installment(link: @product, workflow:, workflow_trigger: "member_cancellation")
    installment_rule = create_installment_rule(installment:, delayed_delivery_time: 1.day)

    @subscription.deactivate!
    @subscription.reload

    job = SendWorkflowInstallmentWorker.jobs.find { |j| j["args"] == [installment.id, installment_rule.version, nil, nil, nil, @subscription.id] }
    assert job
    assert_in_delta((@subscription.deactivated_at + installment_rule.delayed_delivery_time).to_f, job["at"], 1)
  end

  test "#deactivate! does not schedule a member cancellation installment for non-product/seller workflows even if their trigger is member cancellation" do
    deactivate_context
    workflow = create_audience_workflow(seller: @creator, workflow_trigger: "member_cancellation")
    installment = create_published_installment(workflow:, workflow_trigger: "member_cancellation")
    create_installment_rule(installment:, delayed_delivery_time: 1.day)

    @subscription.deactivate!

    assert_equal 0, SendWorkflowInstallmentWorker.jobs.size
  end

  test "#deactivate! does not schedule a member cancellation installment if the seller workflow isn't for member cancellation" do
    deactivate_context
    workflow = create_seller_workflow(seller: @creator, workflow_trigger: nil)
    installment = create_published_installment(workflow:, workflow_trigger: "member_cancellation")
    create_installment_rule(installment:, delayed_delivery_time: 1.day)

    @subscription.deactivate!

    assert_equal 0, SendWorkflowInstallmentWorker.jobs.size
  end

  test "#deactivate! does not schedule a member cancellation installment if the product workflow isn't for member cancellation" do
    deactivate_context
    workflow = create_workflow(seller: @creator, link: @product, workflow_trigger: nil)
    installment = create_published_installment(link: @product, workflow:, workflow_trigger: "member_cancellation")
    create_installment_rule(installment:, delayed_delivery_time: 1.day)

    @subscription.deactivate!

    assert_equal 0, SendWorkflowInstallmentWorker.jobs.size
  end

  test "#deactivate! does not schedule a member cancellation installment if the workflow doesn't apply to the purchase" do
    deactivate_context
    workflow = create_workflow(seller: @creator, link: @product, workflow_trigger: "member_cancellation", created_after: 3.days.ago)
    installment = create_published_installment(link: @product, workflow:, workflow_trigger: "member_cancellation")
    create_installment_rule(installment:, delayed_delivery_time: 1.day)

    # Matches the RSpec: it updates the outer-context @purchase (unrelated to this
    # subscription). The subscription's own sale (@sale) predates the workflow's
    # created_after cutoff, which is what actually keeps the workflow from firing.
    @purchase.update!(created_at: 7.days.ago)

    @subscription.deactivate!

    assert_equal 0, SendWorkflowInstallmentWorker.jobs.size
  end

  test "#deactivate! does not schedule a member cancellation installment if the installment rule is nil" do
    deactivate_context
    workflow = create_workflow(seller: @creator, link: @product, workflow_trigger: "member_cancellation")
    create_published_installment(link: @product, workflow:, workflow_trigger: "member_cancellation")

    @subscription.deactivate!

    assert_equal 0, SendWorkflowInstallmentWorker.jobs.size
  end

  test "#deactivate! does not schedule member cancellation workflow jobs when membership ended due to payment failures" do
    deactivate_context
    workflow = create_seller_workflow(seller: @creator, workflow_trigger: "member_cancellation")
    installment = create_published_installment(workflow:, workflow_trigger: "member_cancellation")
    create_installment_rule(installment:, delayed_delivery_time: 1.day)

    @subscription.update!(cancelled_at: nil, failed_at: 1.hour.ago)
    @subscription.deactivate!

    assert_equal 0, SendWorkflowInstallmentWorker.jobs.size
  end

  test "#deactivate! does not schedule member cancellation workflow jobs when membership reached the end of its fixed-length duration" do
    deactivate_context
    workflow = create_seller_workflow(seller: @creator, workflow_trigger: "member_cancellation")
    installment = create_published_installment(workflow:, workflow_trigger: "member_cancellation")
    create_installment_rule(installment:, delayed_delivery_time: 1.day)

    @subscription.update!(cancelled_at: nil, ended_at: 1.hour.ago)
    @subscription.deactivate!

    assert_equal 0, SendWorkflowInstallmentWorker.jobs.size
  end

  # --- #update_current_plan! -------------------------------------------------
  # setup_subscription charges the original purchase, so each test replays its
  # cassette. The discount-focused examples reuse the shared "creates a new
  # original purchase..." recording, exactly as the RSpec cassette_name overrides.

  UPDATE_PLAN_SHARED_CASSETTE = "Subscription/_update_current_plan_/creates_a_new_original_purchase_with_the_updated_tier_price_and_quantity"
  UPDATE_PLAN_CLEAR_CASSETTE = "Subscription/_update_current_plan_/when_the_original_purchase_has_an_offer_code_discount_with_duration_in_months/clears_the_offer_code_and_discount_when_clear_discount_is_true"

  test "#update_current_plan! archives the existing original purchase" do
    VCR.use_cassette("Subscription/_update_current_plan_/archives_the_existing_original_purchase") do
      setup_subscription
      @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)
      assert_equal true, @original_purchase.reload.is_archived_original_subscription_purchase
    end
  end

  test "#update_current_plan! creates a new original purchase with the updated tier, price, and quantity" do
    VCR.use_cassette("Subscription/_update_current_plan_/creates_a_new_original_purchase_with_the_updated_tier_price_and_quantity") do
      setup_subscription
      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, new_quantity: 2)
      assert_equal new_purchase, @subscription.reload.original_purchase
      new_purchase.reload
      assert_predicate new_purchase, :persisted?
      assert_equal 40_00, new_purchase.displayed_price_cents
      assert_equal [@new_tier], new_purchase.variant_attributes
      assert_equal "not_charged", new_purchase.purchase_state
    end
  end

  test "#update_current_plan! copies correct attributes from the original purchase" do
    VCR.use_cassette("Subscription/_update_current_plan_/copies_correct_attributes_from_the_original_purchase") do
      setup_subscription(free_trial: true, was_product_recommended: true)
      Subscription.any_instance.stubs(:mor_fee_applicable?).returns(false)

      @original_purchase.update!(
        full_name: "Jane Gumroad",
        street_address: "100 Main Street",
        city: "San Francisco",
        state: "CA",
        zip_code: "11111",
        country: "US",
        referrer: "https://gumroad.com",
        ip_country: "USA",
        ip_state: "CA",
        offer_code: create_offer_code(products: [@product], amount_cents: 300),
        affiliate: create_direct_affiliate(seller: @product.user, affiliate_basis_points: 200),
        was_product_recommended: true,
        stripe_transaction_id: "abc123",
        stripe_status: "foo",
        stripe_error_code: "bar",
        error_code: "baz",
        affiliate_credit_cents: 11
      )
      @original_purchase.seller.mark_compliant!(author_name: "ContentModeration")
      @original_purchase.purchase_custom_fields.create!(name: "favorite color", type: CustomField::TYPE_TEXT, value: "Blue")
      @original_purchase.create_recommended_purchase_info(
        recommended_link_id: @original_purchase.link_id,
        recommended_by_link_id: @original_purchase.link_id,
        recommendation_type: RecommendationType::GUMROAD_DISCOVER_RECOMMENDATION,
        is_recurring_purchase: true,
        discover_fee_per_thousand: 300
      )

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, new_quantity: 2)

      %i[seller_id email link_id displayed_price_currency_type full_name
         street_address country state zip_code city ip_address ip_state
         ip_country browser_guid referrer was_product_recommended
         offer_code_id affiliate_id credit_card_id is_free_trial_purchase
         custom_fields].each do |purchase_attr|
        assert_equal @original_purchase.send(purchase_attr), new_purchase.send(purchase_attr), purchase_attr.to_s
      end
      assert_equal @original_purchase.purchase_custom_fields.pluck(:name, :value, :field_type), new_purchase.purchase_custom_fields.pluck(:name, :value, :field_type)

      assert_nil new_purchase.stripe_transaction_id
      assert_nil new_purchase.succeeded_at
      assert_nil new_purchase.stripe_status
      assert_nil new_purchase.stripe_error_code
      assert_nil new_purchase.error_code

      assert_equal 2, new_purchase.quantity
      assert_equal 3400, new_purchase.price_cents
      assert_equal 3400, new_purchase.displayed_price_cents
      assert_equal 1119, new_purchase.fee_cents
      assert_equal 45, new_purchase.affiliate_credit_cents
      assert_equal 3400, new_purchase.total_transaction_cents

      %i[recommended_link_id recommended_by_link_id recommendation_type
         is_recurring_purchase discover_fee_per_thousand].each do |attr|
        assert_equal @original_purchase.recommended_purchase_info.send(attr), new_purchase.recommended_purchase_info.send(attr)
      end
    end
  end

  test "#update_current_plan! creates a purchase event for the new original purchase" do
    VCR.use_cassette("Subscription/_update_current_plan_/creates_a_purchase_event_for_the_new_original_purchase") do
      setup_subscription
      create_purchase_event(purchase: @original_purchase)

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)

      event = new_purchase.events.first
      assert_equal 1, new_purchase.events.size
      assert_equal new_purchase.id, event.purchase_id
      assert_equal new_purchase.price_cents, event.price_cents
      assert_equal false, event.is_recurring_subscription_charge
      assert_equal "not_charged", event.purchase_state
    end
  end

  test "#update_current_plan! does not charge the user" do
    VCR.use_cassette("Subscription/_update_current_plan_/does_not_charge_the_user") do
      setup_subscription
      assert_no_difference -> { @subscription.reload.purchases.not_is_original_subscription_purchase.count } do
        @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)
      end
    end
  end

  test "#update_current_plan! caches the buyer-specific amount when applying a tiered existing-customer discount" do
    VCR.use_cassette(UPDATE_PLAN_SHARED_CASSETTE) do
      setup_subscription
      offer_code = create_tiered_offer_code(for_existing_customers: true, products: [@product], ownership_products: [@product])

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, offer_code:)

      assert_equal 50, new_purchase.purchase_offer_code_discount.offer_code_amount
      assert_equal true, new_purchase.purchase_offer_code_discount.offer_code_is_percent
      assert_equal 10_00, new_purchase.displayed_price_cents
    end
  end

  test "#update_current_plan! does not use the subscription owner to auto-discover discounts for unauthenticated updates" do
    VCR.use_cassette(UPDATE_PLAN_SHARED_CASSETTE) do
      setup_subscription
      create_tiered_offer_code(for_existing_customers: true, code: "autovictim", products: [@product], ownership_products: [@product], user: @product.user)

      new_purchase = @subscription.update_current_plan!(
        new_variants: [@new_tier],
        new_price: @yearly_product_price,
        perceived_price_cents: @new_tier_yearly_price.price_cents,
        authenticated_offer_code_buyer: nil
      )

      assert_nil new_purchase.offer_code
      assert_nil new_purchase.purchase_offer_code_discount
      assert_equal @new_tier_yearly_price.price_cents, new_purchase.displayed_price_cents
    end
  end

  test "#update_current_plan! does not copy an exhausted original discount onto a different auto-discovered tiered discount" do
    VCR.use_cassette(UPDATE_PLAN_SHARED_CASSETTE) do
      setup_subscription
      @original_purchase.update!(created_at: 1.month.ago)
      original_offer_code = create_offer_code(code: "singlecycle", products: [@product], amount_cents: nil, amount_percentage: 50, currency_type: nil, duration_in_billing_cycles: 1)
      @original_purchase.update!(offer_code: original_offer_code)
      @original_purchase.create_purchase_offer_code_discount!(
        offer_code: original_offer_code,
        offer_code_amount: 50,
        offer_code_is_percent: true,
        pre_discount_minimum_price_cents: @original_purchase.minimum_paid_price_cents_per_unit_before_discount,
        duration_in_months: 1
      )
      tiered_offer_code = create_tiered_offer_code(for_existing_customers: true, code: "zeroseedplan", products: [@product], ownership_products: [@product], user: @product.user)

      new_purchase = @subscription.update_current_plan!(
        new_variants: [@new_tier],
        new_price: @yearly_product_price,
        authenticated_offer_code_buyer: @user
      )

      new_discount = new_purchase.purchase_offer_code_discount
      assert_equal tiered_offer_code, new_purchase.offer_code
      assert_equal tiered_offer_code, new_discount.offer_code
      assert_equal 0, new_discount.offer_code_amount
      assert_equal true, new_discount.offer_code_is_percent
      assert_nil new_discount.duration_in_months
      assert_equal @new_tier_yearly_price.price_cents, new_purchase.displayed_price_cents
    end
  end

  test "#update_current_plan! keeps a re-resolved tiered discount when clear_discount is true" do
    VCR.use_cassette(UPDATE_PLAN_SHARED_CASSETTE) do
      setup_subscription
      offer_code = create_tiered_offer_code(for_existing_customers: true, code: "tieredrestart", products: [@product], ownership_products: [@product], user: @product.user)
      @original_purchase.update!(offer_code:)
      @original_purchase.create_purchase_offer_code_discount!(
        offer_code:,
        offer_code_amount: 0,
        offer_code_is_percent: true,
        pre_discount_minimum_price_cents: @original_purchase.minimum_paid_price_cents_per_unit_before_discount,
        duration_in_months: nil
      )

      new_purchase = @subscription.update_current_plan!(
        new_variants: [@new_tier],
        new_price: @yearly_product_price,
        perceived_price_cents: 10_00,
        clear_discount: true,
        authenticated_offer_code_buyer: @user
      )

      assert_equal offer_code, new_purchase.offer_code
      assert_equal 50, new_purchase.purchase_offer_code_discount.offer_code_amount
      assert_equal true, new_purchase.purchase_offer_code_discount.offer_code_is_percent
      assert_equal 10_00, new_purchase.displayed_price_cents
    end
  end

  test "#update_current_plan! keeps a re-resolved non-tiered discount when clear_discount is true" do
    VCR.use_cassette(UPDATE_PLAN_SHARED_CASSETTE) do
      setup_subscription
      original_offer_code = create_offer_code(code: "singlecycle", products: [@product], amount_cents: nil, amount_percentage: 20, currency_type: nil, duration_in_billing_cycles: 1)
      @original_purchase.update!(offer_code: original_offer_code)
      @original_purchase.create_purchase_offer_code_discount!(
        offer_code: original_offer_code,
        offer_code_amount: 20,
        offer_code_is_percent: true,
        pre_discount_minimum_price_cents: @original_purchase.minimum_paid_price_cents_per_unit_before_discount,
        duration_in_months: 1
      )
      replacement_code = create_offer_code(code: "loyalrestart", user: @product.user, products: [@product], ownership_products: [@product], existing_customers_only: true, amount_cents: nil, amount_percentage: 25, currency_type: nil)

      new_purchase = @subscription.update_current_plan!(
        new_variants: [@new_tier],
        new_price: @yearly_product_price,
        perceived_price_cents: 15_00,
        clear_discount: true,
        authenticated_offer_code_buyer: @user
      )

      assert_equal replacement_code, new_purchase.offer_code
      assert_equal 25, new_purchase.purchase_offer_code_discount.offer_code_amount
      assert_equal true, new_purchase.purchase_offer_code_discount.offer_code_is_percent
      assert_equal 15_00, new_purchase.displayed_price_cents
    end
  end

  test "#update_current_plan! does not use the subscription owner to qualify unauthenticated discount updates" do
    VCR.use_cassette(UPDATE_PLAN_SHARED_CASSETTE) do
      setup_subscription
      ownership_product = create_product(user: @product.user)
      create_purchase(link: ownership_product, seller: @product.user, purchaser: @user, price_cents: ownership_product.price_cents)
      offer_code = create_offer_code(code: "existingbuyer", amount_cents: nil, amount_percentage: 100, products: [@product], ownership_products: [ownership_product], existing_customers_only: true, user: @product.user)

      error = assert_raises(Subscription::UpdateFailed) do
        @subscription.update_current_plan!(
          new_variants: [@new_tier],
          new_price: @yearly_product_price,
          offer_code:,
          authenticated_offer_code_buyer: nil
        )
      end
      assert_equal "Sorry, this discount code is only for existing customers.", error.message
      assert_equal @original_purchase, @subscription.reload.original_purchase
    end
  end

  test "#update_current_plan! does not update the creator's balance" do
    VCR.use_cassette("Subscription/_update_current_plan_/does_not_update_the_creator_s_balance") do
      setup_subscription
      creator = @product.user
      assert_equal 1, creator.balances.count
      assert_no_difference -> { creator.reload.balances.count } do
        @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)
      end
    end
  end

  test "#update_current_plan! updating to a PWYW tier calculates displayed_price_cents correctly" do
    VCR.use_cassette("Subscription/_update_current_plan_/updating_to_a_PWYW_tier/calculates_displayed_price_cents_correctly") do
      setup_subscription
      @new_tier.update!(customizable_price: true)
      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, perceived_price_cents: 20_01)
      assert_equal 20_01, new_purchase.reload.displayed_price_cents
    end
  end

  test "#update_current_plan! updating to a PWYW tier with a price that is too low raises an error" do
    VCR.use_cassette("Subscription/_update_current_plan_/updating_to_a_PWYW_tier/with_a_price_that_is_too_low/raises_an_error") do
      setup_subscription
      @new_tier.update!(customizable_price: true)
      error = assert_raises(Subscription::UpdateFailed) do
        @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, perceived_price_cents: 19_99)
      end
      assert_equal "Please enter an amount greater than or equal to the minimum.", error.message
    end
  end

  test "#update_current_plan! when skip_preparing_for_charge is true does not call Stripe or perform any chargeable-related operations" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_skip_preparing_for_charge_is_true/does_not_call_Stripe_or_perform_any_chargeable-related_operations") do
      setup_subscription
      Purchase.any_instance.expects(:load_chargeable_for_charging).never
      Stripe::PaymentIntent.expects(:create).never
      @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, skip_preparing_for_charge: true)
    end
  end

  test "#update_current_plan! when applying a quantity change updates the purchase quantity and price" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_applying_a_quantity_change/updates_the_purchase_quantity_and_price") do
      setup_subscription
      @subscription.update_current_plan!(new_variants: [@subscription.tier], new_price: @subscription.price, new_quantity: 2)
      @subscription.reload
      assert_equal 11_98, @subscription.original_purchase.displayed_price_cents
      assert_equal 2, @subscription.original_purchase.quantity
    end
  end

  test "#update_current_plan! when applying a plan change uses that price as the new price even if product price is higher" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_applying_a_plan_change/uses_that_price_as_the_new_price_even_if_product_price_is_higher") do
      setup_subscription
      @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, perceived_price_cents: 10_00, is_applying_plan_change: true)
      assert_equal 10_00, @subscription.reload.original_purchase.displayed_price_cents
    end
  end

  test "#update_current_plan! when applying a plan change uses that price as the new price even if product price is lower" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_applying_a_plan_change/uses_that_price_as_the_new_price_even_if_product_price_is_lower") do
      setup_subscription
      @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, perceived_price_cents: 30_00, is_applying_plan_change: true)
      assert_equal 30_00, @subscription.reload.original_purchase.displayed_price_cents
    end
  end

  test "#update_current_plan! when applying a plan change and free trial is enabled does not require the new original purchase to be marked a free trial purchase" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_applying_a_plan_change/and_free_trial_is_enabled/does_not_require_the_new_original_purchase_to_be_marked_a_free_trial_purchase") do
      setup_subscription
      @product.update!(free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week)
      @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, perceived_price_cents: 10_00, is_applying_plan_change: true)
    end
  end

  test "#update_current_plan! when applying a plan change but product is no longer for sale still allows the plan to be changed" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_applying_a_plan_change/but_product_is_no_longer_for_sale/still_allows_the_plan_to_be_changed") do
      setup_subscription
      @product.update!(purchase_disabled_at: 1.day.ago)
      @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, perceived_price_cents: 10_00, is_applying_plan_change: true)
      assert_equal 10_00, @subscription.reload.original_purchase.displayed_price_cents
    end
  end

  test "#update_current_plan! when purchase has a license associates the license with the new original_purchase" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_purchase_has_a_license/associates_the_license_with_the_new_original_purchase") do
      setup_subscription
      license = create_license(purchase: @original_purchase)
      @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)
      new_original_purchase = @subscription.reload.original_purchase
      assert_not_equal @original_purchase.id, new_original_purchase.id
      assert_equal new_original_purchase.id, license.reload.purchase_id
    end
  end

  test "#update_current_plan! when purchase was recommended charges the discover fee percentage from the original purchase instead of the current product discover fee" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_purchase_was_recommended/charges_the_discover_fee_percentage_from_the_original_purchase_instead_of_the_current_product_discover_fee") do
      setup_subscription(was_product_recommended: true, discover_fee_per_thousand: 300)
      @product.update!(discover_fee_per_thousand: 400)
      Subscription.any_instance.stubs(:mor_fee_applicable?).returns(false)

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)
      @subscription.reload

      assert_equal 658, new_purchase.fee_cents # 2000*0.329, rounded

      recurring_purchase = @subscription.charge!
      assert_equal "successful", recurring_purchase.purchase_state
      assert_equal 688, recurring_purchase.fee_cents
      assert_equal 300, recurring_purchase.discover_fee_per_thousand
    end
  end

  test "#update_current_plan! when purchase has sent emails associates the emails with the new original_purchase" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_purchase_has_sent_emails/associates_the_emails_with_the_new_original_purchase") do
      setup_subscription
      installment = create_installment(link: @product, seller: @product.user, published_at: Time.current)
      email_info = create_email_info(installment:, purchase: @original_purchase, state: "created")
      @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)
      new_original_purchase = @subscription.reload.original_purchase
      assert_equal new_original_purchase.id, email_info.reload.purchase_id
    end
  end

  test "#update_current_plan! when comments are associated with the purchase updates the comments with the new original_purchase" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_comments_are_associated_with_the_purchase/updates_the_comments_with_the_new_original_purchase") do
      setup_subscription
      purchase = create_purchase(link: create_product, created_at: 1.second.ago)
      comment1 = create_comment(purchase: @original_purchase)
      comment2 = create_comment
      comment3 = create_comment(purchase:)
      comment4 = create_comment(purchase: @original_purchase)

      @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)

      new_original_purchase = @subscription.reload.original_purchase
      assert_equal new_original_purchase.id, comment1.reload.purchase_id
      assert_nil comment2.reload.purchase_id
      assert_equal purchase.id, comment3.reload.purchase_id
      assert_equal new_original_purchase.id, comment4.reload.purchase_id
    end
  end

  test "#update_current_plan! when purchase has a URL redirect creates a URL redirect for the new original_purchase" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_purchase_has_a_URL_redirect/creates_a_URL_redirect_for_the_new_original_purchase") do
      setup_subscription(with_product_files: true)
      @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)
      new_original_purchase = @subscription.reload.original_purchase
      assert_not_equal @original_purchase.id, new_original_purchase.id
      assert new_original_purchase.url_redirect
    end
  end

  test "#update_current_plan! for test subscription marks the new original purchase 'test_successful'" do
    VCR.use_cassette("Subscription/_update_current_plan_/for_test_subscription/marks_the_new_original_purchase_test_successful_") do
      setup_subscription
      @product.update!(user: @user)
      @subscription.update!(is_test_subscription: true)
      @original_purchase.update!(purchase_state: "test_successful", seller: @user)

      @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)

      assert_equal "test_successful", @subscription.reload.original_purchase.purchase_state
    end
  end

  # Shared context for the "offer code discount with duration_in_months" examples.
  def update_plan_offer_code_duration_context
    setup_subscription
    @offer_code = create_offer_code(amount_percentage: 25, products: [@product])
    @original_purchase.update!(offer_code: @offer_code)
  end

  test "#update_current_plan! offer code discount with duration_in_months copies duration_in_months to the new original purchase's discount" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_the_original_purchase_has_an_offer_code_discount_with_duration_in_months/copies_duration_in_months_to_the_new_original_purchase_s_discount") do
      update_plan_offer_code_duration_context
      @offer_code.update!(duration_in_months: 3)
      @original_purchase.create_purchase_offer_code_discount!(
        offer_code: @offer_code, offer_code_amount: 25, offer_code_is_percent: true,
        pre_discount_minimum_price_cents: @original_purchase.minimum_paid_price_cents_per_unit_before_discount, duration_in_months: 3
      )

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)

      new_discount = new_purchase.purchase_offer_code_discount
      assert_predicate new_discount, :present?
      assert_equal 25, new_discount.offer_code_amount
      assert_equal true, new_discount.offer_code_is_percent
      assert_equal 3, new_discount.duration_in_months
    end
  end

  test "#update_current_plan! offer code discount with duration_in_months preserves nil duration_in_months for unlimited discounts" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_the_original_purchase_has_an_offer_code_discount_with_duration_in_months/preserves_nil_duration_in_months_for_unlimited_discounts") do
      update_plan_offer_code_duration_context
      @original_purchase.create_purchase_offer_code_discount!(
        offer_code: @offer_code, offer_code_amount: 25, offer_code_is_percent: true,
        pre_discount_minimum_price_cents: @original_purchase.minimum_paid_price_cents_per_unit_before_discount, duration_in_months: nil
      )

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)

      new_discount = new_purchase.purchase_offer_code_discount
      assert_predicate new_discount, :present?
      assert_nil new_discount.duration_in_months
    end
  end

  test "#update_current_plan! offer code discount with duration_in_months uses current offer code values when offer_code is provided" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_the_original_purchase_has_an_offer_code_discount_with_duration_in_months/uses_current_offer_code_values_when_offer_code_is_provided") do
      update_plan_offer_code_duration_context
      @offer_code.update!(amount_percentage: 50, duration_in_months: 6)
      @original_purchase.create_purchase_offer_code_discount!(
        offer_code: @offer_code, offer_code_amount: 25, offer_code_is_percent: true,
        pre_discount_minimum_price_cents: @original_purchase.minimum_paid_price_cents_per_unit_before_discount, duration_in_months: 1
      )

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, offer_code: @offer_code)

      new_discount = new_purchase.purchase_offer_code_discount
      assert_predicate new_discount, :present?
      assert_equal @offer_code, new_discount.offer_code
      assert_equal 50, new_discount.offer_code_amount
      assert_equal true, new_discount.offer_code_is_percent
      assert_equal 6, new_discount.duration_in_months
      assert_equal new_purchase.minimum_paid_price_cents_per_unit_before_discount, new_discount.pre_discount_minimum_price_cents
    end
  end

  test "#update_current_plan! offer code discount with duration_in_months sets a new offer code on the new purchase when offer_code is a different code" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_the_original_purchase_has_an_offer_code_discount_with_duration_in_months/sets_a_new_offer_code_on_the_new_purchase_when_offer_code_is_a_different_code") do
      update_plan_offer_code_duration_context
      @original_purchase.create_purchase_offer_code_discount!(
        offer_code: @offer_code, offer_code_amount: 25, offer_code_is_percent: true,
        pre_discount_minimum_price_cents: @original_purchase.minimum_paid_price_cents_per_unit_before_discount, duration_in_months: 1
      )

      new_offer_code = create_offer_code(code: "newcode", amount_cents: 1_00, products: [@product])

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, offer_code: new_offer_code, clear_discount: true)

      assert_equal new_offer_code, new_purchase.offer_code
      new_discount = new_purchase.purchase_offer_code_discount
      assert_predicate new_discount, :present?
      assert_equal new_offer_code, new_discount.offer_code
      assert_equal 1_00, new_discount.offer_code_amount
      assert_equal false, new_discount.offer_code_is_percent
    end
  end

  test "#update_current_plan! offer code discount with duration_in_months builds a discount for a new offer code when original had no discount" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_the_original_purchase_has_an_offer_code_discount_with_duration_in_months/builds_a_discount_for_a_new_offer_code_when_original_had_no_discount") do
      update_plan_offer_code_duration_context
      new_offer_code = create_offer_code(code: "newcode", amount_percentage: 30, products: [@product])

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, offer_code: new_offer_code)

      assert_equal new_offer_code, new_purchase.offer_code
      new_discount = new_purchase.purchase_offer_code_discount
      assert_predicate new_discount, :present?
      assert_equal new_offer_code, new_discount.offer_code
      assert_equal 30, new_discount.offer_code_amount
      assert_equal true, new_discount.offer_code_is_percent
    end
  end

  test "#update_current_plan! offer code discount with duration_in_months clears the offer code and discount when clear_discount is true" do
    VCR.use_cassette("Subscription/_update_current_plan_/when_the_original_purchase_has_an_offer_code_discount_with_duration_in_months/clears_the_offer_code_and_discount_when_clear_discount_is_true") do
      update_plan_offer_code_duration_context
      @original_purchase.create_purchase_offer_code_discount!(
        offer_code: @offer_code, offer_code_amount: 25, offer_code_is_percent: true,
        pre_discount_minimum_price_cents: @original_purchase.minimum_paid_price_cents_per_unit_before_discount, duration_in_months: 3
      )

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, clear_discount: true)

      assert_nil new_purchase.offer_code
      assert_nil new_purchase.purchase_offer_code_discount
    end
  end

  test "#update_current_plan! offer code discount with duration_in_months keeps a deleted offer code without applying its discount when clear_deleted_discount is true" do
    VCR.use_cassette(UPDATE_PLAN_CLEAR_CASSETTE) do
      update_plan_offer_code_duration_context
      @offer_code.mark_deleted!
      @original_purchase.create_purchase_offer_code_discount!(
        offer_code: @offer_code, offer_code_amount: 25, offer_code_is_percent: true,
        pre_discount_minimum_price_cents: @original_purchase.minimum_paid_price_cents_per_unit_before_discount, duration_in_months: 3
      )

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, clear_deleted_discount: true)

      assert_equal @offer_code, new_purchase.offer_code
      assert_equal new_purchase.minimum_paid_price_cents_per_unit_before_discount, new_purchase.displayed_price_cents
      assert_equal 0, new_purchase.purchase_offer_code_discount.offer_code_amount
    end
  end

  test "#update_current_plan! offer code discount with duration_in_months keeps a deleted tiered offer code discount when clear_deleted_discount is true" do
    VCR.use_cassette(UPDATE_PLAN_CLEAR_CASSETTE) do
      update_plan_offer_code_duration_context
      tiered_code = create_tiered_offer_code(for_existing_customers: true, code: "tieredclear", user: @product.user, products: [@product], ownership_products: [@product])
      @original_purchase.update!(offer_code: tiered_code)
      @original_purchase.create_purchase_offer_code_discount!(
        offer_code: tiered_code, offer_code_amount: 50, offer_code_is_percent: true,
        pre_discount_minimum_price_cents: @original_purchase.minimum_paid_price_cents_per_unit_before_discount, duration_in_months: nil
      )
      tiered_code.mark_deleted!

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, clear_deleted_discount: true)

      assert_equal tiered_code, new_purchase.offer_code
      assert_equal 50, new_purchase.purchase_offer_code_discount.offer_code_amount
      assert_equal true, new_purchase.purchase_offer_code_discount.offer_code_is_percent
      assert_equal 10_00, new_purchase.displayed_price_cents
    end
  end

  test "#update_current_plan! offer code discount with duration_in_months does not clear an auto-discovered replacement discount when clear_deleted_discount is true" do
    VCR.use_cassette(UPDATE_PLAN_CLEAR_CASSETTE) do
      update_plan_offer_code_duration_context
      @offer_code.update!(duration_in_months: 1)
      @original_purchase.create_purchase_offer_code_discount!(
        offer_code: @offer_code, offer_code_amount: 25, offer_code_is_percent: true,
        pre_discount_minimum_price_cents: @original_purchase.minimum_paid_price_cents_per_unit_before_discount, duration_in_months: 1
      )
      @offer_code.mark_deleted!
      replacement_code = create_offer_code(code: "replacementdiscount", user: @product.user, products: [@product], ownership_products: [@product], existing_customers_only: true, amount_cents: nil, amount_percentage: 25, currency_type: nil)

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, perceived_price_cents: 15_00, clear_deleted_discount: true)

      assert_equal replacement_code, new_purchase.offer_code
      assert_equal 25, new_purchase.purchase_offer_code_discount.offer_code_amount
      assert_equal true, new_purchase.purchase_offer_code_discount.offer_code_is_percent
      assert_equal 15_00, new_purchase.displayed_price_cents
    end
  end

  test "#update_current_plan! for a subscription with fixed length raises an error" do
    VCR.use_cassette("Subscription/_update_current_plan_/for_a_subscription_with_fixed_length/raises_an_error") do
      setup_subscription
      @subscription.update!(charge_occurrence_count: 4)
      error = assert_raises(Subscription::UpdateFailed) do
        @subscription.update_current_plan!(new_variants: [@original_tier], new_price: @yearly_product_price)
      end
      assert_equal "Changing plans for fixed-length subscriptions is not currently supported.", error.message
    end
  end

  test "#update_current_plan! for installment plans raises an error" do
    purchase = create_installment_plan_purchase
    subscription = purchase.subscription
    error = assert_raises(Subscription::UpdateFailed) do
      subscription.update_current_plan!(new_variants: [], new_price: nil)
    end
    assert_equal "Installment plans cannot be updated.", error.message
  end

  # --- last purchase state ---------------------------------------------------

  test "last purchase state failed within time frame is false" do
    VCR.use_cassette("Subscription/last_purchase_state/failed/within_time_frame_is_false") do
      travel_to(Date.current + 3) do
        @subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: @product)
        purchase = create_purchase(is_original_subscription_purchase: true, link: @product, subscription: @subscription)
        purchase.update_attribute(:purchase_state, "failed")
      end
      travel_to(Date.current + 4) do
        assert_not @subscription.purchases.paid.where("succeeded_at > ?", 48.hours.ago).present?
      end
    end
  end

  test "last purchase state failed outside time frame is false" do
    VCR.use_cassette("Subscription/last_purchase_state/failed/outside_time_frame_is_false") do
      travel_to(Date.current + 3) do
        @subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: @product)
        purchase = create_purchase(is_original_subscription_purchase: true, link: @product, subscription: @subscription)
        purchase.update_attribute(:purchase_state, "failed")
      end
      travel_to(Date.current + 6) do
        assert_not @subscription.purchases.paid.where("succeeded_at > ?", 48.hours.ago).present?
      end
    end
  end

  test "last purchase state successful within time frame is true" do
    VCR.use_cassette("Subscription/last_purchase_state/successful/within_time_frame_is_true") do
      travel_to(Date.current + 3) do
        @subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: @product)
        purchase = create_purchase(is_original_subscription_purchase: true, link: @product, subscription: @subscription)
        purchase.update_attribute(:succeeded_at, Time.current)
      end
      travel_to(Date.current + 4) do
        assert @subscription.purchases.paid.where("succeeded_at > ?", 48.hours.ago).present?
      end
    end
  end

  test "last purchase state successful outside time frame is false" do
    VCR.use_cassette("Subscription/last_purchase_state/successful/outside_time_frame_is_false") do
      travel_to(Date.current + 3) do
        @subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: @product)
        purchase = create_purchase(is_original_subscription_purchase: true, link: @product, subscription: @subscription)
        purchase.update_attribute(:succeeded_at, Time.current)
      end
      travel_to(Date.current + 6) do
        assert_not @subscription.purchases.paid.where("succeeded_at > ?", 48.hours.ago).present?
      end
    end
  end

  # --- #cancel_effective_immediately! ----------------------------------------

  test "#cancel_effective_immediately! sends email and sets cancelled attributes" do
    freeze_time do
      mailer = mock
      mailer.stubs(:deliver_later)
      CustomerLowPriorityMailer.expects(:subscription_product_deleted).once.returns(mailer)

      @subscription.cancel_effective_immediately!
      assert_equal Time.current.to_s, @subscription.user_requested_cancellation_at.to_s
      assert_equal Time.current.to_s, @subscription.cancelled_at.to_s
      assert_equal Time.current.to_s, @subscription.deactivated_at.to_s
      assert_equal false, @subscription.cancelled_by_buyer
    end
  end

  test "#cancel_effective_immediately! does not send email but sets cancelled attributes if from chargeback" do
    freeze_time do
      CustomerLowPriorityMailer.expects(:subscription_product_deleted).never

      @subscription.cancel_effective_immediately!(by_buyer: true)
      assert_equal Time.current.to_s, @subscription.user_requested_cancellation_at.to_s
      assert_equal Time.current.to_s, @subscription.cancelled_at.to_s
      assert_equal Time.current.to_s, @subscription.deactivated_at.to_s
      assert_equal true, @subscription.cancelled_by_buyer
    end
  end

  test "#cancel_effective_immediately! enqueues the ping job to notify seller of subscription cancellation" do
    @subscription.cancel_effective_immediately!
    assert_sidekiq_enqueued(PostToPingEndpointsWorker, args: [nil, nil, ResourceSubscription::CANCELLED_RESOURCE_NAME, @subscription.id])
  end

  test "#cancel_effective_immediately! enqueues the ping job to notify seller of subscription ending" do
    @subscription.cancel_effective_immediately!
    assert_sidekiq_enqueued(PostToPingEndpointsWorker, args: [nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, @subscription.id])
  end

  # --- #cancel_immediately_if_pending_cancellation! --------------------------

  test "#cancel_immediately_if_pending_cancellation! enqueues the ping job to notify seller of subscription ending" do
    @subscription.update!(cancelled_at: 1.day.from_now)
    @subscription.cancel_immediately_if_pending_cancellation!
    assert_sidekiq_enqueued(PostToPingEndpointsWorker, args: [nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, @subscription.id])
  end

  # --- #for_tier? ------------------------------------------------------------

  test "#for_tier? returns true if the subscription is currently for that tier" do
    product = create_membership_product_with_preset_tiered_pricing
    tier_1 = product.tiers.first
    subscription = create_membership_purchase(link: product, variant_attributes: [tier_1]).subscription
    assert subscription.for_tier?(tier_1)
  end

  test "#for_tier? returns true if the subscription is pending a change to that tier" do
    product = create_membership_product_with_preset_tiered_pricing
    tier_1 = product.tiers.first
    tier_2 = product.tiers.second
    subscription = create_membership_purchase(link: product, variant_attributes: [tier_1]).subscription
    create_subscription_plan_change(subscription:, tier: tier_2)
    assert_equal true, subscription.for_tier?(tier_1)
    assert_equal true, subscription.for_tier?(tier_2)
  end

  test "#for_tier? returns false if the subscription is not for that tier or pending a change to that tier" do
    product = create_membership_product_with_preset_tiered_pricing
    tier_1 = product.tiers.first
    tier_2 = product.tiers.second
    subscription = create_membership_purchase(link: product, variant_attributes: [tier_1]).subscription
    assert_equal false, subscription.for_tier?(tier_2)
  end

  # --- #pending_cancellation? ------------------------------------------------

  test "#pending_cancellation? returns true if the subscription is pending cancellation" do
    @subscription.cancel!
    assert_equal true, @subscription.pending_cancellation?
  end

  test "#pending_cancellation? returns false if the subscription has already been cancelled" do
    @subscription.cancel_effective_immediately!
    assert_equal false, @subscription.pending_cancellation?
  end

  test "#pending_cancellation? returns false if the subscription was deactivated for some other reason" do
    @subscription.unsubscribe_and_fail!
    assert_equal false, @subscription.pending_cancellation?
  end

  test "#pending_cancellation? returns false for a live subscription" do
    assert_equal false, @subscription.pending_cancellation?
  end

  # --- #cancelled? -----------------------------------------------------------

  test "#cancelled? returns true if the subscription has been cancelled" do
    @subscription.cancel_effective_immediately!
    assert_equal true, @subscription.cancelled?
  end

  test "#cancelled? returns false if the subscription is pending cancellation" do
    @subscription.cancel!
    assert_equal false, @subscription.cancelled?
  end

  test "#cancelled? returns true if the subscription is pending cancellation but flag to treat as cancelled is set" do
    @subscription.cancel!
    assert_equal true, @subscription.cancelled?(treat_pending_cancellation_as_live: false)
  end

  test "#cancelled? returns false if the subscription was deactivated for some other reason" do
    @subscription.unsubscribe_and_fail!
    assert_equal false, @subscription.cancelled?
  end

  test "#cancelled? returns false for a live subscription" do
    assert_equal false, @subscription.cancelled?
  end

  # --- #deactivated? ---------------------------------------------------------

  test "#deactivated? returns true if the subscription has been deactivated" do
    @subscription.deactivated_at = 1.day.ago
    assert_equal true, @subscription.deactivated?
  end

  test "#deactivated? returns false if the subscription has not been deactivated" do
    @subscription.deactivated_at = nil
    assert_equal false, @subscription.deactivated?
  end

  # --- #cancelled_by_seller? -------------------------------------------------

  test "#cancelled_by_seller? returns true for a subscription that was cancelled by the seller" do
    subscription = build_subscription(cancelled_at: 1.day.ago, cancelled_by_buyer: false)
    assert_equal true, subscription.cancelled_by_seller?
  end

  test "#cancelled_by_seller? returns false for a subscription that was cancelled by the buyer" do
    subscription = build_subscription(cancelled_at: 1.day.ago, cancelled_by_buyer: true)
    assert_equal false, subscription.cancelled_by_seller?
  end

  test "#cancelled_by_seller? returns false for a live subscription that is not pending cancellation" do
    subscription = build_subscription
    assert_equal false, subscription.cancelled_by_seller?
  end

  test "#cancelled_by_seller? returns false for a live subscription that is pending cancellation by buyer" do
    subscription = build_subscription(cancelled_at: 1.week.from_now, cancelled_by_buyer: true)
    assert_equal false, subscription.cancelled_by_seller?
  end

  test "#cancelled_by_seller? returns true for a live subscription that is pending cancellation by seller" do
    subscription = build_subscription(cancelled_at: 1.week.from_now, cancelled_by_buyer: false)
    assert_equal true, subscription.cancelled_by_seller?
  end

  test "#cancelled_by_seller? returns false for a failed subscription" do
    subscription = build_subscription(failed_at: 1.day.ago)
    assert_equal false, subscription.cancelled_by_seller?
  end

  test "#cancelled_by_seller? returns false for an ended subscription" do
    subscription = build_subscription(ended_at: 1.day.ago)
    assert_equal false, subscription.cancelled_by_seller?
  end

  # --- #pending_failure? -----------------------------------------------------

  test "#pending_failure? returns false for a subscription in free trial" do
    purchase = create_free_trial_membership_purchase
    assert_equal false, purchase.subscription.pending_failure?
  end

  test "#pending_failure? returns false for a live subscription" do
    subscription = build_subscription
    assert_not subscription.pending_failure?
  end

  test "#pending_failure? returns false for a failed subscription" do
    subscription = build_subscription(failed_at: 1.day.ago)
    assert_equal false, subscription.pending_failure?
  end

  test "#pending_failure? returns true for a live subscription in grace period" do
    subscription = create_subscription
    create_purchase(link: subscription.link, subscription:, is_original_subscription_purchase: true, purchase_state: "successful")
    travel_to 1.month.from_now
    create_purchase(link: subscription.link, subscription:, purchase_state: "failed")

    assert_equal true, subscription.pending_failure?
  end

  # --- #status ---------------------------------------------------------------

  test "#status returns 'alive' for a live subscription" do
    subscription = build_subscription
    assert_equal "alive", subscription.status
  end

  test "#status returns 'pending_failure' for a subscription in a grace period" do
    subscription = create_subscription
    create_purchase(link: subscription.link, subscription:, is_original_subscription_purchase: true, purchase_state: "successful")
    travel_to 1.month.from_now
    create_purchase(link: subscription.link, subscription:, purchase_state: "failed")

    assert_equal "pending_failure", subscription.status
  end

  test "#status returns 'pending_cancellation' for a subscription pending cancellation" do
    subscription = create_subscription(cancelled_at: 1.month.from_now)
    assert_equal "pending_cancellation", subscription.status
  end

  test "#status returns termination reason for a terminated subscription" do
    subscription = create_subscription(failed_at: 1.day.ago, deactivated_at: 1.day.ago)
    assert_equal "failed_payment", subscription.status
  end

  # --- #end_time_of_subscription ---------------------------------------------

  test "#end_time_of_subscription is in 1 month" do
    freeze_time do
      purchase = create_purchase(link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: false, subscription: @subscription)
      purchase.update!(succeeded_at: Time.current)
      assert_equal 1.month.from_now, @subscription.end_time_of_subscription
    end
  end

  test "#end_time_of_subscription is in 3 months" do
    VCR.use_cassette("Subscription/_end_time_of_subscription/is_in_3_months") do
      freeze_time do
        product = create_membership_product(subscription_duration: :quarterly)
        subscription = create_membership_purchase(link: product, succeeded_at: Time.current).subscription
        assert_equal 3.months.from_now, subscription.end_time_of_subscription
      end
    end
  end

  test "#end_time_of_subscription is in 6 months" do
    VCR.use_cassette("Subscription/_end_time_of_subscription/is_in_6_months") do
      freeze_time do
        product = create_membership_product(subscription_duration: :biannually)
        subscription = create_membership_purchase(link: product, succeeded_at: Time.current).subscription
        assert_equal 6.months.from_now, subscription.end_time_of_subscription
      end
    end
  end

  test "#end_time_of_subscription is in 1 year" do
    VCR.use_cassette("Subscription/_end_time_of_subscription/is_in_1_year") do
      freeze_time do
        product = create_membership_product(subscription_duration: :yearly)
        subscription = create_membership_purchase(link: product, succeeded_at: Time.current).subscription
        assert_equal 1.year.from_now, subscription.end_time_of_subscription
      end
    end
  end

  test "#end_time_of_subscription is in 2 years" do
    VCR.use_cassette("Subscription/_end_time_of_subscription/is_in_2_years") do
      freeze_time do
        product = create_membership_product(subscription_duration: :every_two_years)
        subscription = create_membership_purchase(link: product, succeeded_at: Time.current).subscription
        assert_equal 2.years.from_now, subscription.end_time_of_subscription
      end
    end
  end

  test "#end_time_of_subscription is the most recent ended time for test subscription" do
    VCR.use_cassette("Subscription/_end_time_of_subscription/is_the_most_recent_ended_time_for_test_subscription") do
      freeze_time do
        product = create_membership_product(subscription_duration: :quarterly)
        subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product, is_test_subscription: true)
        # RSpec passed a bogus `state:` here (not purchase_state), so this stays a
        # plain successful sale — a test subscription has no test_successful
        # purchases, so end_time falls back to the current time.
        purchase = create_purchase(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true,
                                   subscription:, succeeded_at: Time.current)
        purchase.update!(succeeded_at: Time.current)
        assert_equal Time.current, subscription.end_time_of_subscription
      end
    end
  end

  test "#end_time_of_subscription is Time.current for test subscription without succeeded_at set" do
    VCR.use_cassette("Subscription/_end_time_of_subscription/is_Time_current_for_test_subscription_without_succeeded_at_set") do
      freeze_time do
        product = create_membership_product(subscription_duration: :quarterly)
        subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product, is_test_subscription: true)
        # As above, RSpec's bogus `state:` left this a plain successful sale.
        create_purchase(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true, subscription:)
        assert_equal Time.current, subscription.end_time_of_subscription
      end
    end
  end

  test "#end_time_of_subscription is Time.current when there are no successful purchases" do
    VCR.use_cassette("Subscription/_end_time_of_subscription/is_Time_current_when_there_are_no_successful_purchases") do
      freeze_time do
        product = create_membership_product(subscription_duration: :quarterly)
        subscription = create_subscription(user: create_user(credit_card: create_credit_card), link: product)
        create_purchase(link: product, price_cents: product.price_cents, is_original_subscription_purchase: true, subscription:, purchase_state: "in_progress")
        assert_equal Time.current, subscription.end_time_of_subscription
      end
    end
  end

  test "#end_time_of_subscription returns the time the free trial ends during the free trial" do
    purchase = create_free_trial_membership_purchase
    subscription = purchase.subscription
    assert_equal subscription.free_trial_ends_at, subscription.end_time_of_subscription
  end

  test "#end_time_of_subscription returns the time the free trial ends after the free trial" do
    purchase = create_free_trial_membership_purchase
    subscription = purchase.subscription
    travel_to(1.week.from_now) do
      assert_equal subscription.free_trial_ends_at, subscription.end_time_of_subscription
    end
  end

  test "#end_time_of_subscription returns the current time if it is the only refunded/chargedback purchase" do
    freeze_time do
      purchase = create_membership_purchase
      subscription = purchase.subscription
      purchase.update!(stripe_refunded: true)
      assert_equal Time.current, subscription.end_time_of_subscription

      purchase.update!(stripe_refunded: false, chargeback_date: 1.day.ago)
      assert_equal Time.current, subscription.end_time_of_subscription
    end
  end

  test "#end_time_of_subscription returns the current time if the last paid period has lapsed" do
    purchase = create_membership_purchase
    subscription = purchase.subscription
    end_time = purchase.succeeded_at + subscription.period
    later_purchase = create_purchase(subscription:, link: subscription.link, stripe_refunded: true)
    assert_equal end_time, subscription.end_time_of_subscription

    later_purchase.update!(stripe_refunded: false, chargeback_date: 1.day.ago)
    assert_equal end_time, subscription.end_time_of_subscription
  end

  test "#end_time_of_subscription returns the end time based on a prior purchase that covers the current time" do
    purchase = create_membership_purchase
    subscription = purchase.subscription
    end_time = purchase.succeeded_at + subscription.period
    later_purchase = create_purchase(subscription:, link: subscription.link, stripe_refunded: true)
    assert_equal end_time, subscription.end_time_of_subscription

    later_purchase.update!(stripe_refunded: false, chargeback_date: 1.day.ago)
    assert_equal end_time, subscription.end_time_of_subscription
  end

  # --- #send_renewal_reminders? / #send_renewal_reminder_at ------------------

  test "#send_renewal_reminders? returns false when feature membership_renewal_reminders is disabled" do
    VCR.use_cassette("Subscription/_send_renewal_reminders_/returns_false_when_feature_membership_renewal_reminders_is_disabled") do
      setup_subscription(recurrence: BasePrice::Recurrence::QUARTERLY)
      assert_equal false, @subscription.send_renewal_reminders?
    end
  end

  test "#send_renewal_reminders? returns true when feature membership_renewal_reminders is enabled" do
    VCR.use_cassette("Subscription/_send_renewal_reminders_/returns_true_when_feature_membership_renewal_reminders_is_enabled") do
      setup_subscription(recurrence: BasePrice::Recurrence::QUARTERLY)
      Feature.activate_user(:membership_renewal_reminders, @subscription.seller)
      assert_equal true, @subscription.send_renewal_reminders?
    end
  end

  test "#send_renewal_reminder_at returns one day prior when the subscription is monthly" do
    VCR.use_cassette("Subscription/_send_renewal_reminder_at/when_the_subscription_is_monthly/returns_one_day_prior") do
      setup_subscription(recurrence: BasePrice::Recurrence::MONTHLY)
      travel_to(Time.current) do
        @original_purchase.update!(succeeded_at: Time.current)
        assert_equal 1.month.from_now - 1.day, @subscription.send_renewal_reminder_at
      end
    end
  end

  test "#send_renewal_reminder_at returns seven days prior when the subscription is quarterly" do
    VCR.use_cassette("Subscription/_send_renewal_reminder_at/when_the_subscription_is_quarterly/returns_seven_days_prior") do
      setup_subscription(recurrence: BasePrice::Recurrence::QUARTERLY)
      travel_to(Time.current) do
        @original_purchase.update!(succeeded_at: Time.current)
        assert_equal 3.months.from_now - 7.days, @subscription.send_renewal_reminder_at
      end
    end
  end

  test "#send_renewal_reminder_at returns seven days prior when the subscription is yearly" do
    VCR.use_cassette("Subscription/_send_renewal_reminder_at/when_the_subscription_is_yearly/returns_seven_days_prior") do
      setup_subscription(recurrence: BasePrice::Recurrence::YEARLY)
      travel_to(Time.current) do
        @original_purchase.update!(succeeded_at: Time.current)
        assert_equal 1.year.from_now - 7.days, @subscription.send_renewal_reminder_at
      end
    end
  end

  test "#send_renewal_reminder_at returns seven days prior when the subscription is every two years" do
    VCR.use_cassette("Subscription/_send_renewal_reminder_at/when_the_subscription_is_every_two_years/returns_seven_days_prior") do
      setup_subscription(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS)
      travel_to(Time.current) do
        @original_purchase.update!(succeeded_at: Time.current)
        assert_equal 2.years.from_now - 7.days, @subscription.send_renewal_reminder_at
      end
    end
  end

  # --- #end_time_of_last_paid_period -----------------------------------------

  def end_time_of_last_paid_period_context
    @last_successful_purchase_at = Time.utc(2020, 2, 1)
    @original_purchase = create_membership_purchase(succeeded_at: Time.utc(2020, 1, 1))
    @subscription = @original_purchase.subscription
    create_purchase(link: @subscription.link, subscription: @subscription, succeeded_at: Time.utc(2020, 3, 1), stripe_refunded: true)
    create_purchase(link: @subscription.link, subscription: @subscription, succeeded_at: Time.utc(2020, 4, 1), purchase_state: "failed")
    create_purchase(link: @subscription.link, subscription: @subscription, succeeded_at: Time.utc(2020, 6, 1), chargeback_date: Time.utc(2020, 6, 1))
  end

  test "#end_time_of_last_paid_period returns the paid-through time of the most recent successful, not charged back, fully refunded, or deleted purchase" do
    end_time_of_last_paid_period_context
    create_purchase(link: @subscription.link, subscription: @subscription, succeeded_at: @last_successful_purchase_at)
    assert_equal @last_successful_purchase_at + @subscription.period, @subscription.reload.end_time_of_last_paid_period
  end

  test "#end_time_of_last_paid_period returns the paid-through time of a partially refunded purchase if that is the most recent successful purchase" do
    end_time_of_last_paid_period_context
    create_purchase(link: @subscription.link, subscription: @subscription, stripe_partially_refunded: true, succeeded_at: @last_successful_purchase_at)
    assert_equal @last_successful_purchase_at + @subscription.period, @subscription.end_time_of_last_paid_period
  end

  test "#end_time_of_last_paid_period returns the paid-through time of a chargedback purchase if it is the most recent successful and the chargeback was reversed" do
    end_time_of_last_paid_period_context
    create_purchase(link: @subscription.link, subscription: @subscription, chargeback_date: 5.months.ago, chargeback_reversed: true, succeeded_at: @last_successful_purchase_at)
    assert_equal @last_successful_purchase_at + @subscription.period, @subscription.end_time_of_last_paid_period
  end

  test "#end_time_of_last_paid_period returns the free trial termination time if there are no successful charges" do
    end_time_of_last_paid_period_context
    @original_purchase.update!(purchase_state: "not_charged", succeeded_at: nil)
    free_trial_ends_at = @original_purchase.created_at + 1.week
    @subscription.update!(free_trial_ends_at:)
    assert_equal free_trial_ends_at, @subscription.reload.end_time_of_last_paid_period
  end

  # --- #last_successful_charge_at --------------------------------------------

  test "#last_successful_charge_at returns the succeeded_at time of the most recent successful purchase" do
    subscription = create_subscription
    purchase = create_purchase(link: subscription.link, subscription:, is_original_subscription_purchase: true, succeeded_at: Time.current)
    assert_equal purchase.succeeded_at, subscription.last_successful_charge_at
  end

  test "#last_successful_charge_at returns the succeeded_at time of the most recent successful test purchase" do
    subscription = create_subscription(is_test_subscription: true)
    create_purchase(link: subscription.link, subscription:, is_original_subscription_purchase: true, purchase_state: "test_successful", succeeded_at: 1.day.ago)
    purchase = create_purchase(link: subscription.link, subscription:, purchase_state: "test_successful", succeeded_at: Time.current)
    assert_equal purchase.succeeded_at, subscription.last_successful_charge_at
  end

  test "#last_successful_charge_at returns nil when there are no successful purchases" do
    subscription = create_subscription
    subscription.purchases.update_all(succeeded_at: nil)
    assert_nil subscription.last_successful_charge_at
  end

  # --- #overdue_for_charge? --------------------------------------------------

  test "#overdue_for_charge? returns false before the end of the subscription period" do
    subscription = create_membership_purchase.subscription
    assert_equal false, subscription.overdue_for_charge?
  end

  test "#overdue_for_charge? returns true after the end of the subscription period" do
    subscription = create_membership_purchase.subscription
    travel_to(1.month.from_now + 1.day) do
      assert_equal true, subscription.overdue_for_charge?
    end
  end

  test "#overdue_for_charge? returns true when there are no successful purchases" do
    purchase = create_membership_purchase
    subscription = purchase.subscription
    purchase.update!(purchase_state: "failed")
    assert_equal true, subscription.reload.overdue_for_charge?
  end

  test "#overdue_for_charge? returns false during a free trial" do
    purchase = create_membership_purchase
    subscription = purchase.subscription
    purchase.update!(purchase_state: "not_charged", is_free_trial_purchase: true)
    subscription.update!(free_trial_ends_at: 1.day.from_now)
    assert_equal false, subscription.reload.overdue_for_charge?
  end

  test "#overdue_for_charge? returns true after a free trial" do
    purchase = create_membership_purchase
    subscription = purchase.subscription
    purchase.update!(purchase_state: "not_charged", is_free_trial_purchase: true)
    subscription.update!(free_trial_ends_at: 1.day.ago)
    assert_equal true, subscription.reload.overdue_for_charge?
  end

  # --- #seconds_overdue_for_charge -------------------------------------------

  test "#seconds_overdue_for_charge returns 0 for currently active subscriptions" do
    subscription = create_membership_purchase(succeeded_at: 1.hour.ago).subscription
    assert_equal 0, subscription.seconds_overdue_for_charge
  end

  test "#seconds_overdue_for_charge returns 0 for a subscription with no successful purchases" do
    purchase = create_membership_purchase(succeeded_at: 1.hour.ago)
    purchase.update!(purchase_state: "failed")
    assert_equal 0, purchase.subscription.seconds_overdue_for_charge
  end

  test "#seconds_overdue_for_charge returns the seconds overdue for charge for a subscription overdue for a charge" do
    purchase = create_membership_purchase(succeeded_at: 1.hour.ago)
    subscription = purchase.subscription
    travel_to purchase.succeeded_at + 1.month + 43.seconds do
      assert_equal 43, subscription.seconds_overdue_for_charge
    end
  end

  # --- #has_a_charge_in_progress? --------------------------------------------

  test "#has_a_charge_in_progress? returns true if there's an associated purchase in progress otherwise returns false" do
    purchase = create_membership_purchase(succeeded_at: 1.hour.ago)
    subscription = purchase.subscription
    create_recurring_membership_purchase(subscription:, purchase_state: "failed")

    assert_equal false, subscription.has_a_charge_in_progress?

    in_progress_purchase = create_recurring_membership_purchase(subscription:, purchase_state: "in_progress")
    assert_equal true, subscription.has_a_charge_in_progress?

    in_progress_purchase.update!(purchase_state: "successful")
    assert_equal false, subscription.has_a_charge_in_progress?
  end

  # --- #prorated_discount_price_cents ----------------------------------------

  def prorated_discount_context
    @succeeded_at = Time.utc(2020, 0o4, 0o1)
    product = create_membership_product_with_preset_tiered_pricing
    tier = product.default_tier
    tier_price = tier.prices.find_by(recurrence: BasePrice::Recurrence::MONTHLY) # $3.00
    @subscription = create_subscription(link: product)
    @purchase = create_purchase(link: product, subscription: @subscription, is_original_subscription_purchase: true, succeeded_at: @succeeded_at, price_cents: tier_price.price_cents)
  end

  test "#prorated_discount_price_cents returns 0 when there are no successful purchases" do
    prorated_discount_context
    @subscription.purchases.update_all(succeeded_at: nil)
    assert_equal 0, @subscription.prorated_discount_price_cents
  end

  test "#prorated_discount_price_cents returns the full price before the start of the subscription period" do
    prorated_discount_context
    assert_equal 300, @subscription.prorated_discount_price_cents(calculate_as_of: @succeeded_at - 1.minute)
  end

  test "#prorated_discount_price_cents returns half the price halfway through the subscription period" do
    prorated_discount_context
    calculate_as_of = @succeeded_at + @subscription.current_billing_period_seconds / 2
    assert_equal 150, @subscription.prorated_discount_price_cents(calculate_as_of:)
  end

  test "#prorated_discount_price_cents returns 0 after the end of the subscription period" do
    prorated_discount_context
    assert_equal 0, @subscription.prorated_discount_price_cents(calculate_as_of: Time.utc(2020, 0o5, 0o2))
  end

  test "#prorated_discount_price_cents returns half the price halfway through a month with less than 30 days" do
    prorated_discount_context
    @succeeded_at = Time.utc(2021, 0o2, 0o1)
    @purchase.update!(succeeded_at: @succeeded_at)
    assert_equal 150, @subscription.prorated_discount_price_cents(calculate_as_of: @succeeded_at + 2.weeks)
  end

  test "#prorated_discount_price_cents returns 0 after the end of a month with less than 30 days" do
    prorated_discount_context
    @succeeded_at = Time.utc(2021, 0o2, 0o1)
    @purchase.update!(succeeded_at: @succeeded_at)
    assert_equal 0, @subscription.prorated_discount_price_cents(calculate_as_of: Time.utc(2021, 0o3, 0o1))
  end

  test "#prorated_discount_price_cents prorates against the most recent successful charge when a renewal cycle's price diverges" do
    prorated_discount_context
    renewal_price_cents = 150 # signup was 300; this renewal charged half
    renewal_succeeded_at = @succeeded_at + 1.month
    create_purchase(link: @subscription.link, subscription: @subscription, succeeded_at: renewal_succeeded_at, price_cents: renewal_price_cents)
    calculate_as_of = renewal_succeeded_at + @subscription.current_billing_period_seconds / 2
    assert_equal renewal_price_cents / 2, @subscription.prorated_discount_price_cents(calculate_as_of:)
  end

  test "#prorated_discount_price_cents bases the credit on the full current-period plan price after a mid-period upgrade, not the incremental upgrade charge" do
    prorated_discount_context
    # Mid-period upgrade to a $9.00 plan: the upgrade charge is only the
    # incremental amount ($9.00 minus the credit for the unused half of the
    # original $3.00 period = $7.50), but the subscriber now holds a full
    # $9.00 period. A second upgrade's credit must be based on the $9.00 the
    # current plan is worth, not the $7.50 incremental charge — otherwise the
    # credit from the first upgrade is silently dropped.
    upgraded_plan_price_cents = 900
    upgrade_succeeded_at = @succeeded_at + @subscription.current_billing_period_seconds / 2

    # After an upgrade the (updated) original purchase reflects the new plan's
    # full price; archive the old original purchase like
    # Subscription#update_current_plan! does.
    @purchase.update_flag!(:is_archived_original_subscription_purchase, true, true)
    create_purchase(
      link: @subscription.link, subscription: @subscription,
      is_original_subscription_purchase: true,
      is_updated_original_subscription_purchase: true,
      purchase_state: "not_charged", succeeded_at: nil,
      price_cents: upgraded_plan_price_cents
    )
    create_purchase(
      link: @subscription.link, subscription: @subscription,
      is_upgrade_purchase: true,
      succeeded_at: upgrade_succeeded_at,
      price_cents: 750 # 900 - 150 credit for the unused half of the $3.00 period
    )
    @subscription.reload

    # Halfway through the remainder of the period: 50% of the FULL $9.00
    # current plan price = 450, not 50% of the $7.50 incremental charge (375).
    calculate_as_of = upgrade_succeeded_at + @subscription.current_billing_period_seconds / 2
    assert_equal 450, @subscription.prorated_discount_price_cents(calculate_as_of:)
  end

  test "#prorated_discount_price_cents does not credit the full plan price when the latest upgrade charge was fully refunded" do
    prorated_discount_context
    # A fully refunded purchase stays in the subscription's successful
    # purchases. If the reversed upgrade charge were still treated as a valid
    # upgrade, the subscriber would be credited for the full upgraded plan's
    # value they no longer paid for, making the next charge too low. Instead
    # the credit falls back to the (reversed) charge's own price.
    upgrade_succeeded_at = @succeeded_at + @subscription.current_billing_period_seconds / 2

    @purchase.update_flag!(:is_archived_original_subscription_purchase, true, true)
    create_purchase(
      link: @subscription.link, subscription: @subscription,
      is_original_subscription_purchase: true,
      is_updated_original_subscription_purchase: true,
      purchase_state: "not_charged", succeeded_at: nil,
      price_cents: 900
    )
    create_purchase(
      link: @subscription.link, subscription: @subscription,
      is_upgrade_purchase: true,
      succeeded_at: upgrade_succeeded_at,
      price_cents: 750,
      stripe_refunded: true
    )
    @subscription.reload

    # Halfway through the remainder of the period: 50% of the refunded
    # charge's own $7.50 price = 375, not 50% of the full $9.00 plan (450).
    calculate_as_of = upgrade_succeeded_at + @subscription.current_billing_period_seconds / 2
    assert_equal 375, @subscription.prorated_discount_price_cents(calculate_as_of:)
  end

  test "#prorated_discount_price_cents does not credit the full plan price when the latest upgrade charge was charged back" do
    prorated_discount_context
    upgrade_succeeded_at = @succeeded_at + @subscription.current_billing_period_seconds / 2

    @purchase.update_flag!(:is_archived_original_subscription_purchase, true, true)
    create_purchase(
      link: @subscription.link, subscription: @subscription,
      is_original_subscription_purchase: true,
      is_updated_original_subscription_purchase: true,
      purchase_state: "not_charged", succeeded_at: nil,
      price_cents: 900
    )
    create_purchase(
      link: @subscription.link, subscription: @subscription,
      is_upgrade_purchase: true,
      succeeded_at: upgrade_succeeded_at,
      price_cents: 750,
      chargeback_date: upgrade_succeeded_at + 1.day
    )
    @subscription.reload

    calculate_as_of = upgrade_succeeded_at + @subscription.current_billing_period_seconds / 2
    assert_equal 375, @subscription.prorated_discount_price_cents(calculate_as_of:)
  end

  # --- #current_billing_period_seconds ---------------------------------------

  SECONDS_PER_DAY = 24 * 60 * 60

  test "#current_billing_period_seconds returns the correct number of seconds in a 28 day month" do
    purchase = create_membership_purchase(succeeded_at: Time.utc(2021, 0o2, 0o1))
    assert_equal 28 * SECONDS_PER_DAY, purchase.subscription.current_billing_period_seconds
  end

  test "#current_billing_period_seconds returns the correct number of seconds in a 29 day month" do
    purchase = create_membership_purchase(succeeded_at: Time.utc(2020, 0o2, 0o1))
    assert_equal 29 * SECONDS_PER_DAY, purchase.subscription.current_billing_period_seconds
  end

  test "#current_billing_period_seconds returns the correct number of seconds in a 30 day month" do
    purchase = create_membership_purchase(succeeded_at: Time.utc(2021, 0o4, 0o1))
    assert_equal 30 * SECONDS_PER_DAY, purchase.subscription.current_billing_period_seconds
  end

  test "#current_billing_period_seconds returns the correct number of seconds in a 31 day month" do
    purchase = create_membership_purchase(succeeded_at: Time.utc(2021, 0o1, 0o1))
    assert_equal 31 * SECONDS_PER_DAY, purchase.subscription.current_billing_period_seconds
  end

  test "#current_billing_period_seconds returns the correct number of seconds for a quarterly subscription starting in January" do
    product = create_membership_product_with_preset_tiered_pricing(subscription_duration: "quarterly", recurrence_price_values: [
                                                                     { "quarterly": { enabled: true, price: 3 } },
                                                                     { "quarterly": { enabled: true, price: 5 } }
                                                                   ])
    purchase = create_membership_purchase(link: product, succeeded_at: Time.utc(2021, 0o1, 0o1))
    assert_equal (31 + 28 + 31) * SECONDS_PER_DAY, purchase.subscription.current_billing_period_seconds
  end

  test "#current_billing_period_seconds returns the correct number of seconds for a quarterly subscription starting in June" do
    product = create_membership_product_with_preset_tiered_pricing(subscription_duration: "quarterly", recurrence_price_values: [
                                                                     { "quarterly": { enabled: true, price: 3 } },
                                                                     { "quarterly": { enabled: true, price: 5 } }
                                                                   ])
    purchase = create_membership_purchase(link: product, succeeded_at: Time.utc(2021, 0o6, 0o1))
    assert_equal (30 + 31 + 31) * SECONDS_PER_DAY, purchase.subscription.current_billing_period_seconds
  end

  test "#current_billing_period_seconds returns 0 with no successful charges" do
    subscription = create_subscription
    assert_equal 0, subscription.current_billing_period_seconds
  end

  test "#current_billing_period_seconds returns the duration of the free trial during a free trial" do
    purchased_at = Time.utc(2021, 0o1, 0o1)
    purchase = create_free_trial_membership_purchase(created_at: purchased_at)
    subscription = purchase.subscription
    subscription.update!(free_trial_ends_at: purchased_at + 1.week)
    assert_equal 7 * SECONDS_PER_DAY, subscription.current_billing_period_seconds
  end

  # --- #termination_reason ---------------------------------------------------

  test "#termination_reason returns the correct reason if subscription ended due to fixed period ending" do
    terminated_at = Date.new(2020, 1, 1)
    subscription = build_subscription(ended_at: terminated_at, deactivated_at: terminated_at)
    assert_equal "fixed_subscription_period_ended", subscription.termination_reason
  end

  test "#termination_reason returns the correct reason if subscription was cancelled" do
    terminated_at = Date.new(2020, 1, 1)
    subscription = build_subscription(cancelled_at: terminated_at, deactivated_at: terminated_at)
    assert_equal "cancelled", subscription.termination_reason
  end

  test "#termination_reason returns the correct reason if subscription was cancelled due to failed payments" do
    terminated_at = Date.new(2020, 1, 1)
    subscription = build_subscription(failed_at: terminated_at, deactivated_at: terminated_at)
    assert_equal "failed_payment", subscription.termination_reason
  end

  test "#termination_reason returns nil if the subscription does not have a termination time set" do
    subscription = build_subscription
    assert_nil subscription.termination_reason
  end

  # --- payment options -------------------------------------------------------

  test "payment options for a non-tiered membership subscription has the proper payment option" do
    VCR.use_cassette("Subscription/payment_options/for_a_non-tiered_membership_subscription/has_the_proper_payment_option") do
      user = create_user(credit_card: create_credit_card)
      product = create_subscription_product
      subscription = create_subscription(link: product, user:, created_at: 3.days.ago)
      create_purchase(is_original_subscription_purchase: true, link: product, subscription:, purchaser: user)

      assert_equal 1, subscription.payment_options.count
      assert_equal product.prices.alive.is_buy.last, subscription.payment_options.last.price
    end
  end

  test "payment options for a tiered membership subscription has the proper payment option" do
    VCR.use_cassette("Subscription/payment_options/for_a_tiered_membership_subscription/has_the_proper_payment_option") do
      user = create_user(credit_card: create_credit_card)
      product = create_membership_product
      subscription = create_subscription(link: product, user:, created_at: 3.days.ago)
      create_purchase(is_original_subscription_purchase: true, link: product, subscription:, purchaser: user)

      assert_equal 1, subscription.payment_options.count
      assert_equal product.prices.alive.is_buy.last, subscription.payment_options.last.price
    end
  end

  # --- #expected_completion_time ---------------------------------------------

  test "#expected_completion_time returns nil for non fixed-length subscriptions" do
    freeze_time do
      subscription = create_membership_purchase.subscription
      assert_nil subscription.expected_completion_time
    end
  end

  test "#expected_completion_time calculates end_of_last_paid_period + period * remaining when some charges completed" do
    freeze_time do
      t0 = Time.utc(2023, 1, 1, 12, 0, 0)
      travel_to(t0)
      purchase = create_membership_purchase(succeeded_at: t0)
      subscription = purchase.subscription
      subscription.update!(charge_occurrence_count: 3)
      assert_equal purchase.succeeded_at + 3.months, subscription.expected_completion_time
    end
  end

  test "#expected_completion_time considers free_trial_ends_at during the free trial" do
    freeze_time do
      t0 = Time.utc(2023, 1, 1, 12, 0, 0)
      travel_to(t0)
      free_trial_purchase = create_free_trial_membership_purchase(created_at: t0)
      subscription = free_trial_purchase.subscription
      subscription.update!(charge_occurrence_count: 3)
      assert_equal subscription.free_trial_ends_at + 3.months, subscription.expected_completion_time
    end
  end

  test "#expected_completion_time equals end_of_last_paid_period when all required charges are completed" do
    freeze_time do
      t0 = Time.utc(2023, 1, 1, 12, 0, 0)
      travel_to(t0)
      purchase = create_membership_purchase(succeeded_at: t0)
      subscription = purchase.subscription
      subscription.update!(charge_occurrence_count: 3)
      create_purchase(subscription:, link: subscription.link, succeeded_at: t0 + 1.month)
      create_purchase(subscription:, link: subscription.link, succeeded_at: t0 + 2.months)
      assert_equal true, subscription.charges_completed?
      assert_equal subscription.end_time_of_last_paid_period, subscription.expected_completion_time
    end
  end

  test "#expected_completion_time returns nil when there is no paid period to anchor on" do
    freeze_time do
      t0 = Time.utc(2023, 1, 1, 12, 0, 0)
      travel_to(t0)
      purchase = create_membership_purchase(succeeded_at: t0)
      subscription = purchase.subscription
      subscription.update!(charge_occurrence_count: 3)
      purchase.update!(stripe_refunded: true)
      assert_nil subscription.end_time_of_last_paid_period
      assert_nil subscription.expected_completion_time
    end
  end

  # --- #has_fixed_length? / #single_charge? / #charges_completed? ------------

  test "#has_fixed_length? returns true if charge_occurrence_count is set" do
    assert_equal true, build_subscription(charge_occurrence_count: 1).has_fixed_length?
  end

  test "#has_fixed_length? returns false if charge_occurrence_count is not set" do
    assert_equal false, build_subscription.has_fixed_length?
  end

  test "#single_charge? returns true when the subscription only ever charges once" do
    assert_equal true, build_subscription(charge_occurrence_count: 1).single_charge?
  end

  test "#single_charge? returns false when the subscription charges more than once" do
    assert_equal false, build_subscription(charge_occurrence_count: 2).single_charge?
  end

  test "#single_charge? returns false when the subscription has no fixed length" do
    assert_equal false, build_subscription.single_charge?
  end

  def charges_completed_context
    product = create_membership_product
    @subscription = create_subscription(link: product)
    create_purchase(is_original_subscription_purchase: true, link: product, subscription: @subscription, purchaser: @subscription.user)
    create_purchase(link: product, subscription: @subscription, purchaser: @subscription.user, purchase_state: "failed")
  end

  test "#charges_completed? returns true when the required number of charges are processed" do
    charges_completed_context
    @subscription.update_columns(charge_occurrence_count: 2)
    create_purchase(link: @subscription.link, subscription: @subscription, purchaser: @subscription.user)
    assert_equal true, @subscription.charges_completed?
  end

  test "#charges_completed? returns false when the required number of charges are not processed" do
    charges_completed_context
    @subscription.update_columns(charge_occurrence_count: 2)
    assert_equal false, @subscription.charges_completed?
  end

  test "#charges_completed? returns false when the subscription has no set number of charges" do
    charges_completed_context
    assert_equal false, @subscription.charges_completed?
  end

  # --- #price ----------------------------------------------------------------

  test "#price uses the last_payment_option_id column if it's not nil" do
    payment_option = create_payment_option
    subscription = create_subscription
    subscription.payment_options.delete_all
    subscription.update_columns(last_payment_option_id: payment_option.id)
    assert_equal payment_option.price, subscription.reload.price
  end

  test "#price uses the 'payment_options.alive.last' query if last_payment_option is nil" do
    subscription = create_subscription
    subscription.update_columns(last_payment_option_id: nil)
    assert_equal subscription.payment_options.alive.last.price, subscription.price
  end

  # --- #current_subscription_price_cents -------------------------------------

  test "#current_subscription_price_cents returns the original purchase displayed price when no limited-duration offer code" do
    @subscription.original_purchase.update!(displayed_price_cents: 1234)
    assert_equal 1234, @subscription.current_subscription_price_cents
  end

  def limited_duration_offer_code_context
    @offer_code = create_offer_code(products: [@product], amount_cents: 100, duration_in_billing_cycles: 1)
    @purchase.update!(offer_code: @offer_code, displayed_price_cents: 900)
    @purchase.create_purchase_offer_code_discount!(offer_code: @offer_code, offer_code_amount: 100, offer_code_is_percent: false, pre_discount_minimum_price_cents: 1000, duration_in_billing_cycles: 1)
    @subscription.reload
  end

  test "#current_subscription_price_cents returns the pre-discount price when the discount's duration has elapsed" do
    limited_duration_offer_code_context
    assert_equal 1000, @subscription.current_subscription_price_cents
  end

  test "#current_subscription_price_cents returns the displayed price when the discount's duration has not elapsed" do
    limited_duration_offer_code_context
    @purchase.purchase_offer_code_discount.update!(duration_in_billing_cycles: 2)
    assert_equal 900, @subscription.current_subscription_price_cents
  end

  def installment_plan_price_context
    @ip_product = create_product(name: "Awesome product", user: @seller, price_cents: 1000)
    create_product_installment_plan(link: @ip_product, number_of_installments: 3)
    @ip_subscription = create_subscription(link: @ip_product, is_installment_plan: true)
  end

  test "#current_subscription_price_cents installment plans no discounts returns the next installment price" do
    installment_plan_price_context
    purchase = create_installment_plan_purchase(subscription: @ip_subscription, link: @ip_product)
    assert_equal 334, purchase.price_cents
    assert_equal 333, @ip_subscription.current_subscription_price_cents
  end

  test "#current_subscription_price_cents installment plans no discounts returns the last installment price when the installment plan is completed" do
    installment_plan_price_context
    create_installment_plan_purchase(subscription: @ip_subscription, link: @ip_product)
    create_recurring_installment_plan_purchase(subscription: @ip_subscription, link: @ip_product)
    create_recurring_installment_plan_purchase(subscription: @ip_subscription, link: @ip_product)
    assert_equal true, @ip_subscription.charges_completed?
    assert_equal 333, @ip_subscription.current_subscription_price_cents
  end

  test "#current_subscription_price_cents installment plans with a discount applies to all installments even if it's only for one membership cycle" do
    installment_plan_price_context
    offer_code = create_offer_code(products: [@ip_product], amount_cents: 100, duration_in_billing_cycles: 1)
    purchase = create_installment_plan_purchase(subscription: @ip_subscription, link: @ip_product, offer_code:)
    assert_equal 300, purchase.price_cents
    assert_equal 300, @ip_subscription.current_subscription_price_cents
  end

  test "#current_subscription_price_cents installment plans legacy plan without a snapshot keeps charging the cached discounted price after offer code deleted" do
    installment_plan_price_context
    offer_code = create_offer_code(products: [@ip_product], amount_cents: 100)
    purchase = create_installment_plan_purchase(subscription: @ip_subscription, link: @ip_product, offer_code:)
    # Legacy installment subscriptions predate snapshots; drop it so the price
    # is recomputed from the (deleted) offer code via the cached discount.
    PaymentOption.where(subscription_id: @ip_subscription.id).each { |po| po.installment_plan_snapshot&.destroy }

    assert_equal 300, Subscription.find(@ip_subscription.id).current_subscription_price_cents

    offer_code.mark_deleted!

    assert_equal 300, Purchase.find(purchase.id).minimum_paid_price_cents
    fresh_subscription = Subscription.find(@ip_subscription.id)
    assert_equal 300, fresh_subscription.current_subscription_price_cents
    assert_equal 300, fresh_subscription.build_purchase.perceived_price_cents
  end

  test "#current_subscription_price_cents installment plans keeps charging the snapshot price when the product price later drops below a cached discount" do
    installment_plan_price_context
    offer_code = create_offer_code(products: [@ip_product], amount_cents: 200)
    create_installment_plan_purchase(subscription: @ip_subscription, link: @ip_product, offer_code:)

    agreed_price = Subscription.find(@ip_subscription.id).current_subscription_price_cents
    assert agreed_price > 0

    @ip_product.default_price.update!(price_cents: 100)
    offer_code.mark_deleted!

    assert_equal agreed_price, Subscription.find(@ip_subscription.id).current_subscription_price_cents
  end

  # --- #current_plan_displayed_price_cents -----------------------------------

  test "#current_plan_displayed_price_cents non-tiered memberships returns the original purchase displayed price" do
    @subscription.original_purchase.update!(displayed_price_cents: 1234)
    assert_equal 1234, @subscription.reload.current_subscription_price_cents
  end

  def current_plan_tiered_context
    @cpd_product = create_membership_product_with_preset_tiered_pricing
    @cpd_tier = @cpd_product.default_tier
    @cpd_tier_price = @cpd_tier.prices.find_by(recurrence: BasePrice::Recurrence::MONTHLY) # $3.00
    @cpd_subscription = create_subscription(link: @cpd_product)
    @cpd_purchase = create_purchase(link: @cpd_product, subscription: @cpd_subscription, is_original_subscription_purchase: true, price_cents: @cpd_tier_price.price_cents)
  end

  test "#current_plan_displayed_price_cents tiered non-PWYW tier returns the original purchase displayed price" do
    current_plan_tiered_context
    @cpd_subscription.original_purchase.update!(displayed_price_cents: 1234)
    assert_equal 1234, @cpd_subscription.current_subscription_price_cents
  end

  test "#current_plan_displayed_price_cents tiered PWYW tier returns the tier minimum price if it is lower than the current subscription price" do
    current_plan_tiered_context
    @cpd_tier.update!(customizable_price: true)
    original_price = @cpd_tier_price.price_cents
    @cpd_tier_price.update!(price_cents: original_price - 100)
    assert_equal original_price, @cpd_subscription.current_subscription_price_cents
  end

  test "#current_plan_displayed_price_cents tiered PWYW tier returns the current subscription price if it is lower than the tier price" do
    current_plan_tiered_context
    @cpd_tier.update!(customizable_price: true)
    new_price = @cpd_tier_price.price_cents - 100
    @cpd_subscription.original_purchase.update!(displayed_price_cents: new_price)
    assert_equal new_price, @cpd_subscription.current_subscription_price_cents
  end

  test "#current_plan_displayed_price_cents tiered with offer code returns the cached pre-discount price when the purchase has cached offer code details" do
    current_plan_tiered_context
    offer_code = create_offer_code(products: [@cpd_product], amount_cents: 100)
    @cpd_purchase.update!(offer_code:)
    @cpd_subscription.reload
    @cpd_purchase.create_purchase_offer_code_discount(offer_code:, offer_code_amount: 50, offer_code_is_percent: true, pre_discount_minimum_price_cents: 500)
    assert_equal 500, @cpd_subscription.current_plan_displayed_price_cents
  end

  test "#current_plan_displayed_price_cents tiered with offer code uses the existing offer code to calculate the pre-discount cost when not cached" do
    current_plan_tiered_context
    offer_code = create_offer_code(products: [@cpd_product], amount_cents: 100)
    @cpd_purchase.update!(offer_code:)
    @cpd_subscription.reload
    assert_equal 400, @cpd_subscription.current_plan_displayed_price_cents # $3 paid price + $1 discount
  end

  test "#current_plan_displayed_price_cents tiered with a 100% off offer code and no cache falls back to the purchase displayed price" do
    current_plan_tiered_context
    offer_code = create_offer_code(products: [@cpd_product], amount_cents: 100)
    @cpd_purchase.update!(offer_code:)
    @cpd_subscription.reload
    offer_code.update!(amount_cents: 0, amount_percentage: 100)
    @cpd_purchase.update!(displayed_price_cents: 0)
    assert_equal 0, @cpd_subscription.current_plan_displayed_price_cents
  end

  # --- #resubscribe! ---------------------------------------------------------

  test "#resubscribe! restarts subscription if it is pending cancellation" do
    @subscription.cancel!
    assert_equal true, @subscription.pending_cancellation?
    @subscription.resubscribe!
    assert_equal true, @subscription.alive?(include_pending_cancellation: false)
  end

  test "#resubscribe! restarts subscription if it is cancelled" do
    @subscription.cancel_effective_immediately!
    @subscription.resubscribe!
    assert_equal true, @subscription.alive?(include_pending_cancellation: false)
  end

  test "#resubscribe! creates a subscription restarted event when resubscribing" do
    freeze_time do
      @subscription.cancel_effective_immediately!
      assert_changes -> { @subscription.reload.subscription_events.restarted.count }, from: 0, to: 1 do
        @subscription.resubscribe!
        assert_equal Time.current, @subscription.reload.subscription_events.restarted.last.occurred_at
      end
    end
  end

  test "#resubscribe! restarts subscription if it has failed" do
    @subscription.unsubscribe_and_fail!
    @subscription.resubscribe!
    assert_equal true, @subscription.alive?(include_pending_cancellation: false)
  end

  test "#resubscribe! does not restart subscription if has ended" do
    @subscription.end_subscription!
    @subscription.resubscribe!
    assert_equal false, @subscription.alive?(include_pending_cancellation: false)
  end

  test "#resubscribe! returns true if new charge is not needed" do
    @subscription.cancel!
    assert_equal true, @subscription.pending_cancellation?
    assert_equal true, @subscription.resubscribe!
    assert_equal true, @subscription.alive?(include_pending_cancellation: false)
  end

  test "#resubscribe! returns false if new charge is needed" do
    @subscription.unsubscribe_and_fail!
    assert_equal false, @subscription.resubscribe!
    assert_equal true, @subscription.alive?(include_pending_cancellation: false)
  end

  test "#resubscribe! enqueues activate integrations worker if subscription had been deactivated" do
    @subscription.cancel_effective_immediately!
    @subscription.resubscribe!
    assert_sidekiq_enqueued(ActivateIntegrationsWorker, args: [@subscription.original_purchase.id])
  end

  test "#resubscribe! does not enqueue activate integrations worker if subscription had not been deactivated" do
    @subscription.cancel!
    @subscription.resubscribe!
    assert_equal 0, ActivateIntegrationsWorker.jobs.size
  end

  test "#resubscribe! creates a subscription_event of type restarted" do
    @subscription.cancel_effective_immediately!
    assert_changes -> { @subscription.reload.subscription_events.restarted.count }, from: 0, to: 1 do
      @subscription.resubscribe!
      assert_equal "restarted", @subscription.reload.subscription_events.last.event_type
    end
  end

  test "#resubscribe! schedules any workflow installments missed during the lapsed period" do
    freeze_time do
      @subscription.cancel_effective_immediately!
      travel(1.hour)
      Purchase.any_instance.expects(:reschedule_workflow_installments).with(send_delay: 1.hour.to_i)
      @subscription.resubscribe!
    end
  end

  test "#resubscribe! does not schedule any workflow installments when pending cancellation" do
    @subscription.cancel!
    Purchase.any_instance.expects(:reschedule_workflow_installments).never
    @subscription.resubscribe!
  end

  # --- #send_restart_notifications! ------------------------------------------

  test "#send_restart_notifications! notifies the creator if the subscription had been terminated" do
    @subscription.cancel!
    mail = mock
    mail.stubs(:deliver_later)
    ContactingCreatorMailer.expects(:subscription_restarted).with(@subscription.id).returns(mail)

    @subscription.resubscribe!
    @subscription.send_restart_notifications!
  end

  test "#send_restart_notifications! notifies the customer if the subscription had been terminated" do
    @subscription.cancel!
    mail = mock
    mail.stubs(:deliver_later)
    CustomerMailer.expects(:subscription_restarted).with(@subscription.id, "payment issue resolved").returns(mail)

    @subscription.resubscribe!
    @subscription.send_restart_notifications!("payment issue resolved")
  end

  test "#send_restart_notifications! sends a subscription_restarted notification if the subscription had been terminated" do
    @subscription.cancel!
    mail = mock
    mail.stubs(:deliver_later)
    CustomerMailer.stubs(:subscription_restarted).returns(mail)

    @subscription.resubscribe!
    @subscription.send_restart_notifications!

    assert PostToPingEndpointsWorker.jobs.any? { |job|
      job["args"][0..3] == [nil, nil, ResourceSubscription::SUBSCRIPTION_RESTARTED_RESOURCE_NAME, @subscription.id] &&
        job["args"][4].is_a?(Hash) && job["args"][4].key?("restarted_at")
    }
  end

  # --- #last_resubscribed_at / #last_deactivated_at --------------------------

  test "#last_resubscribed_at returns the last restart time if the subscription has been restarted" do
    freeze_time do
      @subscription.subscription_events.create!(event_type: :deactivated, occurred_at: 1.week.ago)
      last_restart = 3.weeks.ago
      @subscription.subscription_events.create!(event_type: :restarted, occurred_at: last_restart)
      @subscription.subscription_events.create!(event_type: :restarted, occurred_at: 5.weeks.ago)
      assert_equal last_restart, @subscription.last_resubscribed_at
    end
  end

  test "#last_resubscribed_at returns nil if the subscription has not been restarted" do
    freeze_time do
      @subscription.subscription_events.create!(event_type: :deactivated, occurred_at: 1.week.ago)
      assert_nil @subscription.last_resubscribed_at
    end
  end

  test "#last_deactivated_at returns the last deactivation time if the subscription has been deactivated" do
    freeze_time do
      @subscription.subscription_events.create!(event_type: :restarted, occurred_at: 1.week.ago)
      last_deactivation = 3.weeks.ago
      @subscription.subscription_events.create!(event_type: :deactivated, occurred_at: last_deactivation)
      @subscription.subscription_events.create!(event_type: :deactivated, occurred_at: 5.weeks.ago)
      assert_equal last_deactivation, @subscription.last_deactivated_at
    end
  end

  test "#last_deactivated_at returns nil if the subscription has not been deactivated" do
    freeze_time do
      @subscription.subscription_events.create!(event_type: :restarted, occurred_at: 1.week.ago)
      assert_nil @subscription.last_deactivated_at
    end
  end

  # --- #resubscribed? --------------------------------------------------------

  test "#resubscribed? returns false when the subscription has not had an interruption" do
    assert_equal false, @subscription.resubscribed?
  end

  test "#resubscribed? returns true when the subscription has had an interruption" do
    @subscription.subscription_events.create!(event_type: :deactivated, occurred_at: 1.week.ago)
    @subscription.subscription_events.create!(event_type: :restarted, occurred_at: Time.current)
    assert_equal true, @subscription.resubscribed?
  end

  # --- #custom_fields --------------------------------------------------------

  test "#custom_fields returns the custom fields on the original purchase" do
    sub = create_subscription
    archived_original_purchase = create_membership_purchase(subscription: sub)
    archived_original_purchase.purchase_custom_fields << build_purchase_custom_field(name: "name", value: "Amy")
    original_purchase = create_membership_purchase(subscription: sub)
    original_purchase.purchase_custom_fields << build_purchase_custom_field(name: "name", value: "Barbara")
    archived_original_purchase.update!(is_archived_original_subscription_purchase: true)
    renewal_purchase = create_membership_purchase(subscription: sub, is_original_subscription_purchase: false)
    renewal_purchase.purchase_custom_fields << build_purchase_custom_field(name: "name", value: "Carol")
    sub.reload
    assert_equal [{ name: "name", value: "Barbara", type: CustomField::TYPE_TEXT }], sub.custom_fields

    original_purchase.purchase_custom_fields.destroy_all
    assert_equal [], sub.reload.custom_fields
  end

  # --- #has_free_trial? ------------------------------------------------------

  test "#has_free_trial? returns true if free_trial_ends_at is set" do
    assert_equal true, build_subscription(free_trial_ends_at: 1.day.ago).has_free_trial?
  end

  test "#has_free_trial? returns false if free_trial_ends_at is not set" do
    assert_equal false, build_subscription(free_trial_ends_at: nil).has_free_trial?
  end

  # --- #should_exclude_product_review_on_charge_reversal? --------------------

  test "#should_exclude_product_review_on_charge_reversal? returns false if the subscription does not have a free trial" do
    subscription = create_membership_purchase.subscription
    assert_equal false, subscription.should_exclude_product_review_on_charge_reversal?
  end

  test "#should_exclude_product_review_on_charge_reversal? returns true if the initial successful charge does not allow a review" do
    original_purchase = create_free_trial_membership_purchase(should_exclude_product_review: false)
    subscription = original_purchase.subscription
    create_purchase(link: subscription.link, subscription:, stripe_refunded: true)
    assert_equal true, subscription.should_exclude_product_review_on_charge_reversal?
  end

  test "#should_exclude_product_review_on_charge_reversal? returns false if the initial charge disallows a review but the original purchase already excludes reviews" do
    original_purchase = create_free_trial_membership_purchase(should_exclude_product_review: false)
    subscription = original_purchase.subscription
    original_purchase.update!(should_exclude_product_review: true)
    create_purchase(link: subscription.link, subscription:, stripe_refunded: true)
    assert_equal false, subscription.reload.should_exclude_product_review_on_charge_reversal?
  end

  test "#should_exclude_product_review_on_charge_reversal? returns false if the initial successful charge does allow a review" do
    original_purchase = create_free_trial_membership_purchase(should_exclude_product_review: false)
    subscription = original_purchase.subscription
    create_purchase(link: subscription.link, subscription:)
    assert_equal false, subscription.should_exclude_product_review_on_charge_reversal?
  end

  test "#should_exclude_product_review_on_charge_reversal? returns true if there is not yet a successful charge" do
    original_purchase = create_free_trial_membership_purchase(should_exclude_product_review: false)
    subscription = original_purchase.subscription
    assert_equal true, subscription.should_exclude_product_review_on_charge_reversal?
  end

  # --- #alive_or_restartable? ------------------------------------------------

  test "#alive_or_restartable? returns true if ended_at is not set and not cancelled by the seller" do
    assert_equal true, create_subscription.alive_or_restartable?
  end

  test "#alive_or_restartable? returns true if ended_at is not set and the subscription is cancelled by the buyer" do
    assert_equal true, create_subscription(cancelled_at: 1.day.ago, cancelled_by_buyer: true).alive_or_restartable?
  end

  test "#alive_or_restartable? returns false if ended_at is set" do
    assert_equal false, create_subscription(ended_at: 1.day.ago).alive_or_restartable?
  end

  test "#alive_or_restartable? returns false if the subscription is cancelled by the seller" do
    assert_equal false, create_subscription(cancelled_at: 1.day.ago, cancelled_by_buyer: false).alive_or_restartable?
  end

  # --- #alive_at? ------------------------------------------------------------

  test "#alive_at? no events not deactivated returns true if the time is after created_at" do
    subscription = create_membership_purchase(created_at: 2.days.ago).subscription
    purchase_date = subscription.true_original_purchase.created_at
    assert_equal true, subscription.alive_at?(purchase_date + 1.day)
    assert_equal false, subscription.alive_at?(purchase_date - 1.day)
  end

  test "#alive_at? no events deactivated returns true if the time is between created_at and deactivated_at" do
    subscription = create_membership_purchase(created_at: 2.days.ago).subscription
    purchase_date = subscription.true_original_purchase.created_at
    subscription.update!(deactivated_at: purchase_date + 1.month)
    assert_equal true, subscription.alive_at?(purchase_date + 1.week)
    assert_equal false, subscription.alive_at?(subscription.deactivated_at + 2.months)
  end

  test "#alive_at? deactivated and resubscribed returns true if the time is between subscribe and deactivate events" do
    subscription = create_membership_purchase(created_at: 2.days.ago).subscription
    purchase_date = subscription.true_original_purchase.created_at
    create_subscription_event(subscription:, event_type: :deactivated, occurred_at: purchase_date + 2.months)
    create_subscription_event(subscription:, event_type: :restarted, occurred_at: purchase_date + 6.months)
    create_subscription_event(subscription:, event_type: :deactivated, occurred_at: purchase_date + 12.months)

    assert_equal true, subscription.alive_at?(purchase_date + 1.month)
    assert_equal false, subscription.alive_at?(purchase_date + 3.months)
    assert_equal true, subscription.alive_at?(purchase_date + 9.months)
    assert_equal false, subscription.alive_at?(purchase_date + 15.months)
  end

  # --- #discount_applies_to_next_charge? -------------------------------------

  def discount_applies_context
    user = create_user
    product = create_membership_product_with_preset_tiered_pricing(user:)
    offer_code = create_offer_code(products: [product])
    subscription = create_membership_purchase(link: product, offer_code:, variant_attributes: [product.alive_variants.first], price_cents: 200).subscription
    subscription.original_purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false, pre_discount_minimum_price_cents: 300, duration_in_billing_cycles: 1)
    subscription
  end

  test "#discount_applies_to_next_charge? returns false when the offer code is expired" do
    subscription = discount_applies_context
    assert_equal false, subscription.discount_applies_to_next_charge?
  end

  test "#discount_applies_to_next_charge? recomputes after reload when the offer code is expired" do
    subscription = discount_applies_context
    assert_equal false, subscription.discount_applies_to_next_charge?
    subscription.original_purchase.purchase_offer_code_discount.update!(duration_in_billing_cycles: 2)
    subscription.reload
    assert_equal true, subscription.discount_applies_to_next_charge?
  end

  test "#discount_applies_to_next_charge? returns true when the offer code is not expired" do
    subscription = discount_applies_context
    subscription.original_purchase.purchase_offer_code_discount.update!(duration_in_billing_cycles: 2)
    assert_equal true, subscription.discount_applies_to_next_charge?
  end

  test "#discount_applies_to_next_charge? installment plans returns true even if the offer code is only for one membership cycle" do
    product = create_product(name: "Awesome product", user: @seller, price_cents: 1000)
    create_product_installment_plan(link: product, number_of_installments: 3)
    subscription = create_subscription(link: product, is_installment_plan: true)
    offer_code = create_offer_code(products: [product], amount_cents: 100, duration_in_billing_cycles: 1)
    create_installment_plan_purchase(subscription:, link: product, offer_code:)
    assert_equal true, subscription.discount_applies_to_next_charge?
  end

  # --- #auto_renewal_offer_code ----------------------------------------------
  # A subscriber who bought 13 months ago (so the 12-month ownership tier
  # applies), plus a tiered existing-customer renewal discount.

  def auto_renewal_context
    @arc_seller = create_user
    @arc_product = create_membership_product_with_preset_tiered_pricing(user: @arc_seller)
    @arc_buyer = create_user
    purchase = create_membership_purchase(link: @arc_product, purchaser: @arc_buyer, variant_attributes: [@arc_product.alive_variants.first], price_cents: 200, created_at: 13.months.ago)
    purchase.subscription.update!(user: @arc_buyer)
    @arc_subscription = purchase.subscription
    @arc_tiered_code = create_offer_code(
      user: @arc_seller, products: [@arc_product], ownership_products: [@arc_product],
      existing_customers_only: true, amount_cents: nil, amount_percentage: 0, currency_type: nil,
      ownership_duration_tiers: [
        { "months" => 0, "amount_percentage" => 0 },
        { "months" => 12, "amount_percentage" => 50 },
      ]
    )
  end

  test "#auto_renewal_offer_code discovers the best tiered renewal discount for the subscriber" do
    auto_renewal_context
    auto = @arc_subscription.auto_renewal_offer_code
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 50, auto.resolved_percent
  end

  test "#auto_renewal_offer_code ignores universal renewal discounts that exclude the product" do
    auto_renewal_context
    @arc_tiered_code.mark_deleted!
    universal_code = create_universal_offer_code(
      user: @arc_seller, amount_cents: nil, amount_percentage: 0, currency_type: nil,
      ownership_duration_tiers: [
        { "months" => 0, "amount_percentage" => 0 },
        { "months" => 12, "amount_percentage" => 100 },
      ]
    )
    assert_equal universal_code, @arc_subscription.auto_renewal_offer_code.offer_code
    universal_code.update!(excluded_products: [@arc_product])
    assert_nil Subscription.find(@arc_subscription.id).auto_renewal_offer_code
  end

  test "#auto_renewal_offer_code discovers a standalone tiered renewal discount without existing_customers_only" do
    auto_renewal_context
    @arc_tiered_code.mark_deleted!
    standalone_code = create_offer_code(
      user: @arc_seller, products: [@arc_product], amount_cents: nil, amount_percentage: 0, currency_type: nil,
      ownership_duration_tiers: [
        { "months" => 0, "amount_percentage" => 0 },
        { "months" => 12, "amount_percentage" => 50 },
      ]
    )
    auto = @arc_subscription.auto_renewal_offer_code
    assert_equal standalone_code, auto.offer_code
    assert_equal 50, auto.resolved_percent
  end

  test "#auto_renewal_offer_code applies a standalone tiered renewal discount to a guest subscription with no user" do
    auto_renewal_context
    @arc_tiered_code.mark_deleted!
    standalone_code = create_offer_code(
      user: @arc_seller, products: [@arc_product], amount_cents: nil, amount_percentage: 0, currency_type: nil,
      ownership_duration_tiers: [
        { "months" => 0, "amount_percentage" => 0 },
        { "months" => 12, "amount_percentage" => 50 },
      ]
    )
    @arc_subscription.update!(user: nil)
    auto = @arc_subscription.auto_renewal_offer_code
    assert_equal standalone_code, auto.offer_code
    assert_equal 50, auto.resolved_percent
  end

  test "#auto_renewal_offer_code discovers universal existing-customer renewal discounts" do
    auto_renewal_context
    @arc_tiered_code.mark_deleted!
    universal_code = create_universal_offer_code(user: @arc_seller, code: "universalrenewal", ownership_products: [@arc_product], existing_customers_only: true, amount_cents: nil, amount_percentage: 1, currency_type: nil)
    auto = @arc_subscription.auto_renewal_offer_code
    assert_equal universal_code, auto.offer_code
    assert_equal 1, auto.resolved_percent
  end

  test "#auto_renewal_offer_code discovers fixed-amount existing-customer renewal discounts" do
    auto_renewal_context
    @arc_tiered_code.mark_deleted!
    fixed_code = create_offer_code(user: @arc_seller, products: [@arc_product], ownership_products: [@arc_product], existing_customers_only: true, amount_cents: 50, amount_percentage: nil, currency_type: @arc_product.price_currency_type)
    auto = @arc_subscription.auto_renewal_offer_code
    renewal_purchase = @arc_subscription.build_purchase
    assert_equal fixed_code, auto.offer_code
    assert_equal 50, auto.offer_code_amount
    assert_equal false, auto.offer_code_is_percent
    assert_equal 150, @arc_subscription.current_subscription_price_cents
    assert_equal 50, renewal_purchase.purchase_offer_code_discount.offer_code_amount
    assert_equal false, renewal_purchase.purchase_offer_code_discount.offer_code_is_percent
  end

  test "#auto_renewal_offer_code ignores inactive renewal discounts" do
    auto_renewal_context
    create_offer_code(user: @arc_seller, code: "expiredrenewal", products: [@arc_product], ownership_products: [@arc_product], existing_customers_only: true, amount_cents: nil, amount_percentage: 60, currency_type: nil, valid_at: 2.days.ago, expires_at: 1.day.ago)
    auto = @arc_subscription.auto_renewal_offer_code
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 50, auto.resolved_percent
  end

  test "#auto_renewal_offer_code ignores renewal discounts capped to billing cycles" do
    auto_renewal_context
    @arc_tiered_code.mark_deleted!
    create_offer_code(user: @arc_seller, products: [@arc_product], ownership_products: [@arc_product], existing_customers_only: true, amount_cents: nil, amount_percentage: 60, currency_type: nil, duration_in_billing_cycles: 1)
    assert_nil @arc_subscription.auto_renewal_offer_code
  end

  test "#auto_renewal_offer_code ignores sold-out renewal discounts" do
    auto_renewal_context
    sold_out_code = create_offer_code(user: @arc_seller, code: "soldoutrenewal", products: [@arc_product], ownership_products: [@arc_product], existing_customers_only: true, amount_cents: nil, amount_percentage: 60, currency_type: nil, max_purchase_count: 1)
    create_purchase(link: @arc_product, offer_code: sold_out_code)
    auto = @arc_subscription.auto_renewal_offer_code
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 50, auto.resolved_percent
  end

  test "#auto_renewal_offer_code ignores renewal discounts with unmet minimum quantity" do
    auto_renewal_context
    create_offer_code(user: @arc_seller, code: "minimumquantityrenewal", products: [@arc_product], ownership_products: [@arc_product], existing_customers_only: true, amount_cents: nil, amount_percentage: 60, currency_type: nil, minimum_quantity: 2)
    auto = @arc_subscription.auto_renewal_offer_code
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 50, auto.resolved_percent
  end

  test "#auto_renewal_offer_code ignores renewal discounts with unmet minimum amount" do
    auto_renewal_context
    create_offer_code(user: @arc_seller, code: "minimumamountrenewal", products: [@arc_product], ownership_products: [@arc_product], existing_customers_only: true, amount_cents: nil, amount_percentage: 60, currency_type: nil, minimum_amount_cents: 10_000)
    auto = @arc_subscription.auto_renewal_offer_code
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 50, auto.resolved_percent
  end

  test "#auto_renewal_offer_code uses the selected PWYW renewal price for minimum amount checks" do
    auto_renewal_context
    @arc_tiered_code.update!(minimum_amount_cents: 1_200)
    @arc_subscription.original_purchase.update!(price_cents: 1_500, displayed_price_cents: 1_500)
    assert @arc_subscription.original_purchase.minimum_paid_price_cents_per_unit_before_discount < @arc_tiered_code.minimum_amount_cents
    auto = @arc_subscription.auto_renewal_offer_code
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 50, auto.resolved_percent
    assert_equal 750, @arc_subscription.current_subscription_price_cents
  end

  test "#auto_renewal_offer_code keeps the selected PWYW renewal price when the cached tier is zero percent" do
    auto_renewal_context
    original_purchase = @arc_subscription.original_purchase
    original_purchase.update!(offer_code: @arc_tiered_code, price_cents: 1_500, displayed_price_cents: 1_500, created_at: 1.month.ago)
    original_purchase.create_purchase_offer_code_discount!(offer_code: @arc_tiered_code, offer_code_amount: 0, offer_code_is_percent: true, pre_discount_minimum_price_cents: 200, duration_in_months: nil)
    auto = @arc_subscription.auto_renewal_offer_code
    renewal_purchase = @arc_subscription.build_purchase
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 0, auto.resolved_percent
    assert_equal 1_500, @arc_subscription.current_subscription_price_cents
    assert_equal @arc_tiered_code, renewal_purchase.offer_code
    assert_nil renewal_purchase.purchase_offer_code_discount
  end

  test "#auto_renewal_offer_code handles a cached 100 percent PWYW tier" do
    auto_renewal_context
    @arc_tiered_code.update!(amount_percentage: 100, ownership_duration_tiers: [
                               { "months" => 0, "amount_percentage" => 100 },
                               { "months" => 12, "amount_percentage" => 100 },
                             ])
    original_purchase = @arc_subscription.original_purchase
    original_purchase.update_columns(offer_code_id: @arc_tiered_code.id, price_cents: 0, displayed_price_cents: 1_500, created_at: 1.month.ago)
    original_purchase.create_purchase_offer_code_discount!(offer_code: @arc_tiered_code, offer_code_amount: 100, offer_code_is_percent: true, pre_discount_minimum_price_cents: 200, duration_in_months: nil)
    assert_equal 0, @arc_subscription.current_subscription_price_cents
  end

  test "#auto_renewal_offer_code keeps the selected PWYW renewal price when the cached tier is non-zero percent" do
    auto_renewal_context
    @arc_tiered_code.update!(amount_percentage: 25, ownership_duration_tiers: [
                               { "months" => 0, "amount_percentage" => 25 },
                               { "months" => 12, "amount_percentage" => 50 },
                             ])
    original_purchase = @arc_subscription.original_purchase
    original_purchase.update!(offer_code: @arc_tiered_code, price_cents: 1_125, displayed_price_cents: 1_125, created_at: 1.month.ago)
    original_purchase.create_purchase_offer_code_discount!(offer_code: @arc_tiered_code, offer_code_amount: 25, offer_code_is_percent: true, pre_discount_minimum_price_cents: 200, duration_in_months: nil)
    auto = @arc_subscription.auto_renewal_offer_code
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 25, auto.resolved_percent
    assert_equal 1_125, @arc_subscription.current_subscription_price_cents
  end

  test "#auto_renewal_offer_code applies advanced tiers to the selected PWYW renewal price after a non-zero cached tier" do
    auto_renewal_context
    @arc_tiered_code.update!(amount_percentage: 30, ownership_duration_tiers: [
                               { "months" => 0, "amount_percentage" => 30 },
                               { "months" => 12, "amount_percentage" => 60 },
                             ])
    original_purchase = @arc_subscription.original_purchase
    original_purchase.update!(offer_code: @arc_tiered_code, price_cents: 420, displayed_price_cents: 420)
    original_purchase.create_purchase_offer_code_discount!(offer_code: @arc_tiered_code, offer_code_amount: 30, offer_code_is_percent: true, pre_discount_minimum_price_cents: 500, duration_in_months: nil)
    auto = @arc_subscription.auto_renewal_offer_code
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 60, auto.resolved_percent
    assert_equal 240, @arc_subscription.current_subscription_price_cents
  end

  test "#auto_renewal_offer_code applies the advanced tier to the selected PWYW renewal price" do
    auto_renewal_context
    original_purchase = @arc_subscription.original_purchase
    original_purchase.update!(offer_code: @arc_tiered_code, price_cents: 1_500, displayed_price_cents: 1_500)
    original_purchase.create_purchase_offer_code_discount!(offer_code: @arc_tiered_code, offer_code_amount: 0, offer_code_is_percent: true, pre_discount_minimum_price_cents: 200, duration_in_months: nil)
    auto = @arc_subscription.auto_renewal_offer_code
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 50, auto.resolved_percent
    assert_equal 750, @arc_subscription.current_subscription_price_cents
  end

  test "#auto_renewal_offer_code recomputes after reload" do
    auto_renewal_context
    assert_equal @arc_tiered_code, @arc_subscription.auto_renewal_offer_code.offer_code
    @arc_tiered_code.mark_deleted!
    replacement_code = create_offer_code(user: @arc_seller, code: "replacementrenewal", products: [@arc_product], ownership_products: [@arc_product], existing_customers_only: true, amount_cents: nil, amount_percentage: 25, currency_type: nil)
    @arc_subscription.reload
    assert_equal replacement_code, @arc_subscription.auto_renewal_offer_code.offer_code
  end

  test "#auto_renewal_offer_code memoizes missing renewal discounts until reload" do
    auto_renewal_context
    @arc_tiered_code.mark_deleted!
    @arc_subscription.expects(:compute_auto_renewal_offer_code).with(@arc_buyer).once.returns(nil)
    assert_nil @arc_subscription.auto_renewal_offer_code
    assert_nil @arc_subscription.auto_renewal_offer_code
  end

  test "#auto_renewal_offer_code does not reuse subscriber-memoized discounts for explicit guest checks" do
    auto_renewal_context
    assert_equal @arc_tiered_code, @arc_subscription.auto_renewal_offer_code.offer_code
    assert_nil @arc_subscription.auto_renewal_offer_code(authenticated_offer_code_buyer: nil)
  end

  test "#auto_renewal_offer_code returns nil when the original purchase already carries a still-applicable discount" do
    auto_renewal_context
    offer_code = create_offer_code(user: @arc_seller, code: "stillapplies", products: [@arc_product], ownership_products: [@arc_product], existing_customers_only: true, amount_cents: nil, amount_percentage: 25, currency_type: nil)
    @arc_subscription.original_purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 25, offer_code_is_percent: true, pre_discount_minimum_price_cents: 200, duration_in_months: nil)
    assert_nil @arc_subscription.auto_renewal_offer_code
  end

  test "#auto_renewal_offer_code ignores deleted zeroed original discounts when discovering renewal discounts" do
    auto_renewal_context
    @arc_tiered_code.mark_deleted!
    deleted_code = create_offer_code(user: @arc_seller, code: "deletedoriginal", products: [@arc_product], amount_cents: 50, currency_type: @arc_product.price_currency_type)
    @arc_subscription.original_purchase.update!(offer_code: deleted_code)
    @arc_subscription.original_purchase.create_purchase_offer_code_discount!(offer_code: deleted_code, offer_code_amount: 0, offer_code_is_percent: false, pre_discount_minimum_price_cents: 200, duration_in_months: nil)
    deleted_code.mark_deleted!
    replacement_code = create_offer_code(user: @arc_seller, code: "replacementafterdeleted", products: [@arc_product], ownership_products: [@arc_product], existing_customers_only: true, amount_cents: nil, amount_percentage: 25, currency_type: nil)
    auto = @arc_subscription.auto_renewal_offer_code
    assert_equal replacement_code, auto.offer_code
    assert_equal 25, auto.resolved_percent
    assert_equal 150, @arc_subscription.current_subscription_price_cents
  end

  # The "re-evaluates … tiered discounts attached to the original purchase"
  # examples share the setup of a cached 0% tier on the original purchase.
  def re_evaluate_tiered_context
    auto_renewal_context
    @arc_subscription.original_purchase.update!(offer_code: @arc_tiered_code)
    @arc_subscription.original_purchase.create_purchase_offer_code_discount!(offer_code: @arc_tiered_code, offer_code_amount: 0, offer_code_is_percent: true, pre_discount_minimum_price_cents: 200, duration_in_months: nil)
  end

  test "#auto_renewal_offer_code re-evaluates tiered discounts attached to the original purchase" do
    re_evaluate_tiered_context
    auto = @arc_subscription.auto_renewal_offer_code
    renewal_purchase = @arc_subscription.build_purchase
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 50, auto.resolved_percent
    assert_equal 100, @arc_subscription.current_subscription_price_cents
    assert_equal 50, renewal_purchase.purchase_offer_code_discount.offer_code_amount
  end

  test "#auto_renewal_offer_code re-evaluates capped tiered discounts attached to the original purchase" do
    auto_renewal_context
    original_purchase = @arc_subscription.original_purchase
    original_purchase.update!(offer_code: @arc_tiered_code, quantity: 1)
    original_purchase.create_purchase_offer_code_discount!(offer_code: @arc_tiered_code, offer_code_amount: 0, offer_code_is_percent: true, pre_discount_minimum_price_cents: 200, duration_in_months: nil)
    @arc_tiered_code.update!(max_purchase_count: 1)
    assert_not @arc_tiered_code.reload.is_valid_for_purchase?
    auto = @arc_subscription.auto_renewal_offer_code
    renewal_purchase = @arc_subscription.build_purchase
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 50, auto.resolved_percent
    assert_equal 100, @arc_subscription.current_subscription_price_cents
    assert_equal 50, renewal_purchase.purchase_offer_code_discount.offer_code_amount
  end

  test "#auto_renewal_offer_code re-evaluates minimum-quantity tiered discounts attached to the original purchase" do
    auto_renewal_context
    original_purchase = @arc_subscription.original_purchase
    original_purchase.update!(offer_code: @arc_tiered_code, quantity: 1)
    original_purchase.create_purchase_offer_code_discount!(offer_code: @arc_tiered_code, offer_code_amount: 0, offer_code_is_percent: true, pre_discount_minimum_price_cents: 200, duration_in_months: nil)
    @arc_tiered_code.update!(minimum_quantity: 2)
    auto = @arc_subscription.auto_renewal_offer_code
    renewal_purchase = @arc_subscription.build_purchase
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 50, auto.resolved_percent
    assert_equal 100, @arc_subscription.current_subscription_price_cents
    assert_equal 50, renewal_purchase.purchase_offer_code_discount.offer_code_amount
  end

  test "#auto_renewal_offer_code re-evaluates minimum-amount tiered discounts attached to the original purchase" do
    auto_renewal_context
    original_purchase = @arc_subscription.original_purchase
    original_purchase.update!(offer_code: @arc_tiered_code, price_cents: 1_125, displayed_price_cents: 1_125)
    original_purchase.create_purchase_offer_code_discount!(offer_code: @arc_tiered_code, offer_code_amount: 25, offer_code_is_percent: true, pre_discount_minimum_price_cents: 200, duration_in_months: nil)
    @arc_tiered_code.update!(amount_percentage: 25, minimum_amount_cents: 2_000, ownership_duration_tiers: [
                               { "months" => 0, "amount_percentage" => 25 },
                               { "months" => 12, "amount_percentage" => 50 },
                             ])
    auto = @arc_subscription.auto_renewal_offer_code
    renewal_purchase = @arc_subscription.build_purchase
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 50, auto.resolved_percent
    assert_equal 750, @arc_subscription.current_subscription_price_cents
    assert_equal 50, renewal_purchase.purchase_offer_code_discount.offer_code_amount
  end

  test "#auto_renewal_offer_code re-evaluates inactive tiered discounts attached to the original purchase" do
    re_evaluate_tiered_context
    @arc_tiered_code.update!(valid_at: 2.days.ago, expires_at: 1.day.ago)
    auto = @arc_subscription.auto_renewal_offer_code
    renewal_purchase = @arc_subscription.build_purchase
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 50, auto.resolved_percent
    assert_equal 100, @arc_subscription.current_subscription_price_cents
    assert_equal 50, renewal_purchase.purchase_offer_code_discount.offer_code_amount
  end

  test "#auto_renewal_offer_code re-evaluates soft-deleted tiered discounts attached to the original purchase" do
    re_evaluate_tiered_context
    @arc_tiered_code.mark_deleted!
    auto = @arc_subscription.auto_renewal_offer_code
    renewal_purchase = @arc_subscription.build_purchase
    assert_equal @arc_tiered_code, auto.offer_code
    assert_equal 50, auto.resolved_percent
    assert_equal 100, @arc_subscription.current_subscription_price_cents
    assert_equal 50, renewal_purchase.purchase_offer_code_discount.offer_code_amount
  end

  test "#auto_renewal_offer_code records the auto-discovered discount on the renewal purchase" do
    auto_renewal_context
    renewal_purchase = @arc_subscription.build_purchase
    assert_equal @arc_tiered_code, renewal_purchase.offer_code
    assert_predicate renewal_purchase.purchase_offer_code_discount, :present?
    assert_equal 50, renewal_purchase.purchase_offer_code_discount.offer_code_amount
    assert_equal true, renewal_purchase.purchase_offer_code_discount.offer_code_is_percent
  end

  test "#auto_renewal_offer_code records the auto-discovered discount's pre-discount price per unit" do
    auto_renewal_context
    pre_discount_price = @arc_subscription.original_purchase.minimum_paid_price_cents_per_unit_before_discount
    @arc_subscription.original_purchase.update!(quantity: 3, price_cents: pre_discount_price * 3)
    renewal_purchase = @arc_subscription.build_purchase
    assert_equal pre_discount_price, renewal_purchase.purchase_offer_code_discount.pre_discount_minimum_price_cents
  end

  # --- #cookie_key -----------------------------------------------------------

  test "#cookie_key returns the cookie key" do
    assert_equal "subscription_#{@subscription.external_id_numeric}", @subscription.cookie_key
  end

  # --- #emails ---------------------------------------------------------------

  test "#emails returns a hash of relevant emails when the subscription has a user" do
    user = create_user(email: "user@example.com")
    subscription = create_subscription(user:)
    create_membership_purchase(subscription:, email: "purchase@example.com")
    assert_equal({ subscription: "user@example.com", purchase: "purchase@example.com", user: "user@example.com" }, subscription.emails)
  end

  test "#emails returns a hash of relevant emails when the subscription doesn't have a user" do
    subscription = create_subscription(user: nil)
    create_membership_purchase(subscription:, email: "purchase@example.com")
    assert_equal({ subscription: "purchase@example.com", purchase: "purchase@example.com", user: nil }, subscription.emails)
  end

  test "#emails returns giftee email as purchase and subscription emails when the subscription is a gift" do
    subscription = create_subscription(user: nil)
    gift = create_gift(giftee_email: "giftee@example.com")
    create_membership_purchase(subscription:, email: "purchase@example.com", gift_given: gift, is_gift_sender_purchase: true)
    assert_equal({ subscription: "giftee@example.com", purchase: "giftee@example.com", user: nil }, subscription.emails)
  end

  # --- #email ----------------------------------------------------------------

  test "#email returns user's form_email when user is present" do
    subscription = create_subscription
    purchase = create_membership_purchase(subscription:, email: "purchase@example.com")
    subscription.stubs(:original_purchase).returns(purchase)
    assert_equal subscription.user.form_email, subscription.email
  end

  test "#email returns purchase email when user is not present" do
    subscription = create_subscription
    purchase = create_membership_purchase(subscription:, email: "purchase@example.com")
    subscription.stubs(:original_purchase).returns(purchase)
    subscription.update!(user: nil)
    assert_equal purchase.email, subscription.email
  end

  test "#email returns giftee email when user is not present and the subscription is a gift" do
    subscription = create_subscription
    purchase = create_membership_purchase(subscription:, email: "purchase@example.com")
    subscription.stubs(:original_purchase).returns(purchase)
    subscription.update!(user: nil)
    gift = create_gift(giftee_email: "giftee@example.com")
    subscription.true_original_purchase.update!(is_gift_sender_purchase: true, gift_given: gift)
    assert_equal gift.giftee_email, subscription.email
  end

  # --- #refresh_token --------------------------------------------------------

  test "#refresh_token sets a new token and expiration date" do
    subscription = create_subscription(token: nil, token_expires_at: nil)
    subscription.refresh_token
    assert_not_nil subscription.token
    assert_in_delta Subscription::TOKEN_VALIDITY.from_now.to_f, subscription.token_expires_at.to_f, 1
  end

  test "#refresh_token returns the newly set token" do
    subscription = create_subscription(token: nil, token_expires_at: nil)
    assert_not_nil subscription.refresh_token
  end

  # --- #gift? ----------------------------------------------------------------

  test "#gift? returns true when the original purchase is a gift sender purchase" do
    product = create_membership_product
    subscription = build_subscription(link: product)
    original_purchase = build_purchase(link: product, variant_attributes: [product.alive_variants.first], is_original_subscription_purchase: true)
    original_purchase.is_gift_sender_purchase = true
    original_purchase.gift_given = create_gift
    subscription.stubs(:true_original_purchase).returns(original_purchase)
    assert_equal true, subscription.gift?
  end

  test "#gift? returns false when the original purchase does not have a gift" do
    product = create_membership_product
    subscription = build_subscription(link: product)
    original_purchase = build_purchase(link: product, variant_attributes: [product.alive_variants.first], is_original_subscription_purchase: true)
    subscription.stubs(:true_original_purchase).returns(original_purchase)
    assert_equal false, subscription.gift?
  end

  # --- #grant_access_to_product? ---------------------------------------------

  test "#grant_access_to_product? installment plans returns false if the subscription has failed" do
    subscription = create_installment_plan_purchase.subscription
    subscription.unsubscribe_and_fail!
    assert_equal false, subscription.grant_access_to_product?
  end

  test "#grant_access_to_product? installment plans returns false if the subscription is pending cancellation" do
    freeze_time do
      subscription = create_installment_plan_purchase.subscription
      subscription.cancel!(by_seller: true)
      assert subscription.cancelled_at.future?
      assert_equal false, subscription.grant_access_to_product?
    end
  end

  test "#grant_access_to_product? installment plans returns true even when the subscription has ended" do
    subscription = create_installment_plan_purchase.subscription
    assert_equal true, subscription.grant_access_to_product?
    subscription.end_subscription!
    assert_equal true, subscription.grant_access_to_product?
  end

  test "#grant_access_to_product? memberships blocks access when cancelled if configured" do
    subscription = create_membership_purchase.subscription
    subscription.link.update!(block_access_after_membership_cancellation: false)
    subscription.cancel!
    assert_equal true, subscription.grant_access_to_product?
    subscription.link.update!(block_access_after_membership_cancellation: true)
    assert_equal true, subscription.grant_access_to_product?
    subscription.cancel_immediately_if_pending_cancellation!
    assert_equal false, subscription.grant_access_to_product?
  end

  test "#grant_access_to_product? memberships blocks access when failed if configured" do
    subscription = create_membership_purchase.subscription
    subscription.link.update!(block_access_after_membership_cancellation: false)
    subscription.unsubscribe_and_fail!
    assert_equal true, subscription.grant_access_to_product?
    subscription.link.update!(block_access_after_membership_cancellation: true)
    assert_equal false, subscription.grant_access_to_product?
  end

  test "#grant_access_to_product? memberships blocks access when ended if configured" do
    subscription = create_membership_purchase.subscription
    subscription.link.update!(block_access_after_membership_cancellation: false)
    subscription.end_subscription!
    assert_equal true, subscription.grant_access_to_product?
    subscription.link.update!(block_access_after_membership_cancellation: true)
    assert_equal false, subscription.grant_access_to_product?
  end

  # --- offer code persistence for subsequent charges -------------------------

  def offer_code_persistence_installment_context(offer_code_attrs = { amount_cents: 500 })
    seller = create_user
    product = create_product(user: seller, price_cents: 3000)
    create_product_installment_plan(link: product, number_of_installments: 3)
    offer_code = create_offer_code(products: [product], **offer_code_attrs)
    buyer = create_user
    [product, offer_code, buyer]
  end

  test "offer code persistence installment plans preserves the discount for subsequent installments when offer code is deleted" do
    product, offer_code, buyer = offer_code_persistence_installment_context
    purchase = create_installment_plan_purchase(link: product, offer_code:, purchaser: buyer)
    subscription = purchase.subscription
    offer_code.mark_deleted!
    new_purchase = subscription.build_purchase
    assert_predicate new_purchase.purchase_offer_code_discount, :present?
    assert_equal 500, new_purchase.purchase_offer_code_discount.offer_code_amount
    assert_equal false, new_purchase.purchase_offer_code_discount.offer_code_is_percent
  end

  test "offer code persistence installment plans preserves the discount for subsequent installments when offer code expires" do
    product, offer_code, buyer = offer_code_persistence_installment_context
    offer_code.update!(valid_at: 1.week.ago, expires_at: 1.day.from_now)
    purchase = create_installment_plan_purchase(link: product, offer_code:, purchaser: buyer)
    subscription = purchase.subscription
    offer_code.update!(expires_at: 1.day.ago)
    new_purchase = subscription.build_purchase
    assert_predicate new_purchase.purchase_offer_code_discount, :present?
    assert_equal 500, new_purchase.purchase_offer_code_discount.offer_code_amount
  end

  test "offer code persistence installment plans preserves the discount for subsequent installments when offer code reaches max usage" do
    product, offer_code, buyer = offer_code_persistence_installment_context
    offer_code.update!(max_purchase_count: 1)
    purchase = create_installment_plan_purchase(link: product, offer_code:, purchaser: buyer)
    subscription = purchase.subscription
    assert offer_code.reload.quantity_left <= 0
    new_purchase = subscription.build_purchase
    assert_predicate new_purchase.purchase_offer_code_discount, :present?
    assert_equal 500, new_purchase.purchase_offer_code_discount.offer_code_amount
  end

  test "offer code persistence installment plans uses the original snapshotted amount when offer code amount changes" do
    product, offer_code, buyer = offer_code_persistence_installment_context
    purchase = create_installment_plan_purchase(link: product, offer_code:, purchaser: buyer)
    subscription = purchase.subscription
    offer_code.update!(amount_cents: 100)
    new_purchase = subscription.build_purchase
    assert_equal 500, new_purchase.purchase_offer_code_discount.offer_code_amount
  end

  test "offer code persistence installment plans does not count subsequent installments towards max purchases" do
    product, offer_code, buyer = offer_code_persistence_installment_context
    offer_code.update!(max_purchase_count: 1)
    purchase = create_installment_plan_purchase(link: product, offer_code:, purchaser: buyer)
    subscription = purchase.subscription
    new_purchase = subscription.build_purchase
    assert_equal true, new_purchase.does_not_count_towards_max_purchases
  end

  test "offer code persistence installment plans passes offer code validation for subsequent installments" do
    product, offer_code, buyer = offer_code_persistence_installment_context
    offer_code.update!(max_purchase_count: 1)
    purchase = create_installment_plan_purchase(link: product, offer_code:, purchaser: buyer)
    subscription = purchase.subscription
    offer_code.mark_deleted!
    new_purchase = subscription.build_purchase
    new_purchase.valid?
    assert_empty new_purchase.errors[:base]
  end

  test "offer code persistence installment plans preserves percentage discount when offer code is deleted" do
    product, _offer_code, buyer = offer_code_persistence_installment_context
    percent_offer_code = create_offer_code(products: [product], amount_percentage: 25, code: "PERCENT25")
    purchase = create_installment_plan_purchase(link: product, offer_code: percent_offer_code, purchaser: buyer)
    subscription = purchase.subscription
    percent_offer_code.mark_deleted!
    new_purchase = subscription.build_purchase
    assert_predicate new_purchase.purchase_offer_code_discount, :present?
    assert_equal 25, new_purchase.purchase_offer_code_discount.offer_code_amount
    assert_equal true, new_purchase.purchase_offer_code_discount.offer_code_is_percent
  end

  def offer_code_persistence_membership_context(duration_in_months: 3)
    seller = create_user
    product = create_membership_product_with_preset_tiered_pricing(user: seller)
    offer_code = create_offer_code(products: [product], amount_cents: 100, duration_in_months:)
    buyer = create_user
    [product, offer_code, buyer]
  end

  test "offer code persistence memberships with duration preserves the discount for subsequent charges when offer code is deleted within duration" do
    product, offer_code, buyer = offer_code_persistence_membership_context
    purchase = create_membership_purchase(link: product, offer_code:, purchaser: buyer, variant_attributes: [product.alive_variants.first])
    subscription = purchase.subscription
    subscription.original_purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false, pre_discount_minimum_price_cents: 300, duration_in_months: 3)
    offer_code.mark_deleted!
    new_purchase = subscription.build_purchase
    assert_predicate new_purchase.purchase_offer_code_discount, :present?
    assert_equal 100, new_purchase.purchase_offer_code_discount.offer_code_amount
    assert_equal 3, new_purchase.purchase_offer_code_discount.duration_in_months
  end

  test "offer code persistence memberships with duration preserves the discount for subsequent charges when offer code expires within duration" do
    product, offer_code, buyer = offer_code_persistence_membership_context
    offer_code.update!(valid_at: 1.week.ago, expires_at: 1.day.from_now)
    purchase = create_membership_purchase(link: product, offer_code:, purchaser: buyer, variant_attributes: [product.alive_variants.first])
    subscription = purchase.subscription
    subscription.original_purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false, pre_discount_minimum_price_cents: 300, duration_in_months: 3)
    offer_code.update!(expires_at: 1.day.ago)
    new_purchase = subscription.build_purchase
    assert_predicate new_purchase.purchase_offer_code_discount, :present?
    assert_equal 100, new_purchase.purchase_offer_code_discount.offer_code_amount
  end

  test "offer code persistence memberships with duration does not apply the discount when duration has elapsed" do
    product, offer_code, buyer = offer_code_persistence_membership_context(duration_in_months: 3)
    purchase = create_membership_purchase(link: product, offer_code:, purchaser: buyer, variant_attributes: [product.alive_variants.first])
    subscription = purchase.subscription
    subscription.original_purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false, pre_discount_minimum_price_cents: 300, duration_in_months: 1)
    create_membership_purchase(subscription:, link: product, purchaser: buyer, variant_attributes: [product.alive_variants.first])
    new_purchase = subscription.build_purchase
    assert_nil new_purchase.purchase_offer_code_discount
  end

  test "offer code persistence backwards compatibility falls back to live offer code when original purchase has no cached discount" do
    seller = create_user
    product = create_membership_product_with_preset_tiered_pricing(user: seller)
    offer_code = create_offer_code(products: [product], amount_cents: 100)
    buyer = create_user
    purchase = create_membership_purchase(link: product, offer_code:, purchaser: buyer, variant_attributes: [product.alive_variants.first])
    subscription = purchase.subscription
    subscription.original_purchase.purchase_offer_code_discount&.destroy
    new_purchase = subscription.build_purchase
    assert_equal offer_code, new_purchase.offer_code
    assert_nil new_purchase.purchase_offer_code_discount
  end

  test "offer code persistence backwards compatibility does not create a discount when purchase has no offer code" do
    seller = create_user
    product = create_membership_product_with_preset_tiered_pricing(user: seller)
    buyer = create_user
    purchase = create_membership_purchase(link: product, purchaser: buyer, variant_attributes: [product.alive_variants.first])
    subscription = purchase.subscription
    new_purchase = subscription.build_purchase
    assert_nil new_purchase.offer_code
    assert_nil new_purchase.purchase_offer_code_discount
  end

  # --- #update_business_vat_id! ----------------------------------------------

  test "#update_business_vat_id! updates subscription's business_vat_id when not already set" do
    subscription = create_subscription(link: create_subscription_product, business_vat_id: nil)
    subscription.update_business_vat_id!("IE6388047V")
    assert_equal "IE6388047V", subscription.reload.business_vat_id
  end

  test "#update_business_vat_id! does not update subscription's business_vat_id when already set" do
    subscription = create_subscription(link: create_subscription_product, business_vat_id: nil)
    subscription.update!(business_vat_id: "DE123456789")
    subscription.update_business_vat_id!("IE6388047V")
    assert_equal "DE123456789", subscription.reload.business_vat_id
  end

  test "#update_business_vat_id! does not update subscription's business_vat_id when nil is provided" do
    subscription = create_subscription(link: create_subscription_product, business_vat_id: nil)
    subscription.update_business_vat_id!(nil)
    assert_nil subscription.reload.business_vat_id
  end

  test "#update_business_vat_id! does not update subscription's business_vat_id when empty string is provided" do
    subscription = create_subscription(link: create_subscription_product, business_vat_id: nil)
    subscription.update_business_vat_id!("")
    assert_nil subscription.reload.business_vat_id
  end
end
