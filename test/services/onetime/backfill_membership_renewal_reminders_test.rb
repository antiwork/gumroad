# frozen_string_literal: true

require "test_helper"

class Onetime::BackfillMembershipRenewalRemindersTest < ActiveSupport::TestCase
  LOCK_KEY = Onetime::BackfillMembershipRenewalReminders::LOCK_KEY

  setup do
    $redis.del(LOCK_KEY)
    # The real rollout turned this flag on globally; the backfill exists to cover the
    # subscriptions that predate that, so the tests mirror it.
    Feature.activate(:membership_renewal_reminders)
  end

  teardown do
    Feature.deactivate(:membership_renewal_reminders)
    $redis.del(LOCK_KEY)
    RecurringChargeReminderWorker.clear
  end

  # Sidekiq is in fake mode, so assert on the recorded jobs directly. `at:` checks a
  # scheduled (perform_at) job's run time to the second.
  def assert_sidekiq_enqueued(worker, args:, at: nil)
    job = worker.jobs.find { |j| j["args"] == args }
    assert job, "expected #{worker} to be enqueued with #{args.inspect}"
    assert_in_delta at.to_f, job["at"], 1 if at
  end

  # The purchase below is created "now", so each test pins the flag flip relative to it:
  # in the future means the subscription predates the flip and is the backfill's business,
  # in the past means its own purchase already scheduled the reminder.
  def run_backfill(dry_run: false, enabled_before: 1.minute.from_now)
    Onetime::BackfillMembershipRenewalReminders.process(dry_run:, enabled_before:)
  end

  # A membership subscription with its original purchase, which is what the population
  # being backfilled looks like. Creating the purchase enqueues the reminder itself when
  # the flag is on, so the queue is cleared afterwards and the tests count only what the
  # backfill adds.
  def create_eligible_subscription
    seller = create_user
    product = create_membership_product(user: seller)
    subscription = create_subscription(link: product)
    create_membership_purchase(link: product, subscription:)
    RecurringChargeReminderWorker.clear
    subscription.reload
  end

  test "schedules the renewal reminder for a subscription that predates the flag flip" do
    subscription = create_eligible_subscription

    summary = run_backfill

    assert_sidekiq_enqueued(RecurringChargeReminderWorker, args: [subscription.id], at: subscription.send_renewal_reminder_at)
    assert_equal 1, summary[:eligible]
    assert_equal 1, summary[:scheduled]
  end

  test "skips a subscription that already got a reminder from its own purchase" do
    create_eligible_subscription

    summary = run_backfill(enabled_before: 1.minute.ago)

    assert_equal 1, summary[:considered]
    assert_equal 0, summary[:eligible]
    assert_equal 1, summary[:skipped]
    assert_equal 0, summary[:scheduled]
  end

  test "a dry run reports the population without scheduling or claiming the lock" do
    subscription = create_eligible_subscription

    summary = run_backfill(dry_run: true)

    assert_equal 0, RecurringChargeReminderWorker.jobs.size
    assert_equal 1, summary[:eligible]
    assert_equal 0, summary[:scheduled]

    # The claim is what makes a rerun safe, so a dry run must leave it takeable.
    run_backfill
    assert_sidekiq_enqueued(RecurringChargeReminderWorker, args: [subscription.id])
  end

  test "refuses a second live run instead of double emailing the same buyer" do
    create_eligible_subscription
    run_backfill

    error = assert_raises(RuntimeError) { run_backfill }

    assert_match(/already ran or is running/, error.message)
  end

  test "skips subscriptions whose seller does not have the flag" do
    create_eligible_subscription
    Feature.deactivate(:membership_renewal_reminders)

    summary = run_backfill(dry_run: true)

    assert_equal 1, summary[:considered]
    assert_equal 0, summary[:eligible]
    assert_equal 1, summary[:skipped]
  end

  test "skips a subscription that is no longer alive" do
    subscription = create_eligible_subscription
    subscription.update!(failed_at: Time.current)

    summary = run_backfill(dry_run: true)

    assert_equal 1, summary[:considered]
    assert_equal 0, summary[:eligible]
    assert_equal 1, summary[:skipped]
  end

  test "does not consider cancelled subscriptions" do
    subscription = create_eligible_subscription
    subscription.update!(cancelled_at: 1.hour.from_now)

    summary = run_backfill(dry_run: true)

    assert_equal 0, summary[:considered]
  end

  test "a row that raises is counted and does not abort the run" do
    create_eligible_subscription
    Subscription.any_instance.stubs(:send_renewal_reminder_at).raises(NoMethodError)

    summary = run_backfill

    assert_equal 1, summary[:considered]
    assert_equal 0, summary[:scheduled]
    assert_equal 1, summary[:errors]
  end
end
