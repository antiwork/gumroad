# frozen_string_literal: true

require "test_helper"

class Onetime::BackfillMembershipRenewalRemindersTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  CURSOR_KEY = Onetime::BackfillMembershipRenewalReminders::CURSOR_KEY
  RUNNING_KEY = Onetime::BackfillMembershipRenewalReminders::RUNNING_KEY
  ATTEMPTS_KEY = "onetime:backfill_membership_renewal_reminders:attempts"
  FAILED_IDS_KEY = "onetime:backfill_membership_renewal_reminders:failed_ids"

  setup do
    $redis.del(CURSOR_KEY, RUNNING_KEY, ATTEMPTS_KEY, FAILED_IDS_KEY)
    # The real rollout turned this flag on globally; the backfill exists to cover the
    # subscriptions that predate that, so the tests mirror it.
    Feature.activate(:membership_renewal_reminders)
  end

  teardown do
    Feature.deactivate(:membership_renewal_reminders)
    $redis.del(CURSOR_KEY, RUNNING_KEY, ATTEMPTS_KEY, FAILED_IDS_KEY)
    RecurringChargeReminderWorker.clear
  end

  # Sidekiq is in fake mode, so assert on the recorded jobs directly. `at:` checks a
  # scheduled (perform_at) job's run time to the second.
  def assert_sidekiq_enqueued(worker, args:, at: nil)
    job = worker.jobs.find { |j| j["args"] == args }
    assert job, "expected #{worker} to be enqueued with #{args.inspect}"
    return unless at

    assert job["at"], "expected #{worker} to be scheduled for #{at}, not enqueued to run now"
    assert_in_delta at.to_f, job["at"], 1
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

  test "a dry run reports the population without scheduling or moving the cursor" do
    subscription = create_eligible_subscription

    summary = run_backfill(dry_run: true)

    assert_equal 0, RecurringChargeReminderWorker.jobs.size
    assert_equal 1, summary[:eligible]
    assert_equal 0, summary[:scheduled]
    assert_nil $redis.get(CURSOR_KEY)

    run_backfill
    assert_sidekiq_enqueued(RecurringChargeReminderWorker, args: [subscription.id])
  end

  test "a rerun after the cursor is lost emails the buyer once" do
    subscription = create_eligible_subscription
    run_backfill
    $redis.del(CURSOR_KEY)
    run_backfill

    jobs = RecurringChargeReminderWorker.jobs.select { |j| j["args"] == [subscription.id] }
    assert_equal 2, jobs.size
    travel_to(Time.zone.at(jobs.map { |j| j["at"] }.max)) do
      assert_enqueued_emails(1) { jobs.each { |j| RecurringChargeReminderWorker.new.perform(*j["args"]) } }
    end
  end

  test "a rerun after a finished run schedules nothing" do
    create_eligible_subscription
    run_backfill
    RecurringChargeReminderWorker.clear

    summary = run_backfill

    assert_equal 0, summary[:considered]
    assert_equal 0, RecurringChargeReminderWorker.jobs.size
  end

  test "an interrupted run resumes after the last row it handled" do
    first = create_eligible_subscription
    second = create_eligible_subscription
    Subscription.any_instance.stubs(:send_renewal_reminders?).returns(true).then.raises(Interrupt)

    assert_raises(Interrupt) { run_backfill }
    assert_nil $redis.get(RUNNING_KEY), "a crashed run must not block its retry"

    Subscription.any_instance.unstub(:send_renewal_reminders?)
    RecurringChargeReminderWorker.clear
    summary = run_backfill

    assert_equal 1, summary[:scheduled]
    assert_sidekiq_enqueued(RecurringChargeReminderWorker, args: [second.id])
    assert_not RecurringChargeReminderWorker.jobs.any? { |j| j["args"] == [first.id] }
  end

  test "refuses to start while another run holds the running key" do
    create_eligible_subscription
    $redis.set(RUNNING_KEY, 1)

    assert_raises(RuntimeError) { run_backfill }
    assert_equal 0, RecurringChargeReminderWorker.jobs.size
  end

  test "counts reminders already past their lead time and spreads them before the charge" do
    subscription = create_eligible_subscription
    renews_at = subscription.end_time_of_subscription

    travel_to(renews_at - 12.hours) do
      summary = run_backfill

      assert_equal 1, summary[:due_immediately]
      job = RecurringChargeReminderWorker.jobs.find { |j| j["args"] == [subscription.id] }
      assert job
      assert_operator job["at"], :>=, Time.current.to_f - 1
      assert_operator job["at"], :<=, (Time.current + 1.hour).to_f
    end
  end

  test "skips a subscription whose renewal date has already passed" do
    subscription = create_eligible_subscription

    travel_to(subscription.end_time_of_subscription + 1.day) do
      summary = run_backfill

      assert_equal 1, summary[:considered]
      assert_equal 0, summary[:eligible]
      assert_equal 1, summary[:skipped]
      assert_equal 0, RecurringChargeReminderWorker.jobs.size
    end
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

  test "stops at a row whose enqueue raised so the next run schedules it" do
    first = create_eligible_subscription
    second = create_eligible_subscription
    enqueue = RecurringChargeReminderWorker.method(:perform_at)
    RecurringChargeReminderWorker.stub(:perform_at, ->(at, id, *args) { id == first.id ? raise(Redis::CannotConnectError) : enqueue.call(at, id, *args) }) do
      assert_equal 1, run_backfill[:errors]
    end

    run_backfill

    assert_sidekiq_enqueued(RecurringChargeReminderWorker, args: [first.id])
    assert_sidekiq_enqueued(RecurringChargeReminderWorker, args: [second.id])
  end

  test "a row that keeps failing is stepped over instead of stalling every subscription after it" do
    bad = create_eligible_subscription
    good = create_eligible_subscription
    enqueue = RecurringChargeReminderWorker.method(:perform_at)
    RecurringChargeReminderWorker.stub(:perform_at, ->(at, id, *args) { id == bad.id ? nil : enqueue.call(at, id, *args) }) do
      # The production cap is 3; hard-coded so mutating the constant cannot spin this loop.
      3.times do |attempt|
        assert_equal 1, run_backfill[:errors]
        assert_operator $redis.get(CURSOR_KEY).to_i, :<, bad.id if attempt < 2
      end
    end

    assert_equal [bad.id], $redis.smembers(FAILED_IDS_KEY).map(&:to_i)
    assert_sidekiq_enqueued(RecurringChargeReminderWorker, args: [good.id])
    assert_equal good.id.to_s, $redis.get(CURSOR_KEY)
  end

  test "a successful retry clears the row's attempt count" do
    subscription = create_eligible_subscription
    RecurringChargeReminderWorker.stubs(:perform_at).returns(nil)
    run_backfill
    assert_equal "1", $redis.hget(ATTEMPTS_KEY, subscription.id.to_s)

    RecurringChargeReminderWorker.unstub(:perform_at)
    assert_equal 1, run_backfill[:scheduled]
    assert_nil $redis.hget(ATTEMPTS_KEY, subscription.id.to_s)
    assert_empty $redis.smembers(FAILED_IDS_KEY)
  end

  test "a dry run with a failing row leaves attempts, failed ids and the cursor untouched" do
    create_eligible_subscription
    create_eligible_subscription
    Subscription.any_instance.stubs(:end_time_of_subscription).raises(Redis::CannotConnectError)

    summary = run_backfill(dry_run: true)

    assert_equal 2, summary[:errors]
    assert_nil $redis.get(CURSOR_KEY)
    assert_empty $redis.hgetall(ATTEMPTS_KEY)
    assert_empty $redis.smembers(FAILED_IDS_KEY)
  end

  # Simulates RUNNING_KEY expiring under this run and another run claiming it and saving its own cursor.
  def take_over_lease
    $redis.set(RUNNING_KEY, "other-run", ex: 30)
    $redis.set(CURSOR_KEY, "999999")
  end

  def assert_other_run_untouched
    assert_equal "other-run", $redis.get(RUNNING_KEY)
    assert_equal "999999", $redis.get(CURSOR_KEY)
  end

  test "a run that lost its lease stops without moving the new run's cursor or releasing its claim" do
    create_eligible_subscription
    second = create_eligible_subscription
    enqueue = RecurringChargeReminderWorker.method(:perform_at)
    RecurringChargeReminderWorker.stub(:perform_at, lambda { |at, id, *args|
      take_over_lease
      enqueue.call(at, id, *args)
    }) do
      error = assert_raises(StandardError) { run_backfill }
      assert_equal "Onetime::BackfillMembershipRenewalReminders::LeaseLost", error.class.name
    end

    assert_other_run_untouched
    assert_not RecurringChargeReminderWorker.jobs.any? { |j| j["args"] == [second.id] }
  end

  test "a run that lost its lease before enqueuing a row does not enqueue it" do
    first = create_eligible_subscription
    second = create_eligible_subscription
    Subscription.any_instance.stubs(:in_free_trial?).with { take_over_lease if $redis.get(CURSOR_KEY) == first.id.to_s; true }.returns(false)

    error = assert_raises(StandardError) { run_backfill }
    assert_equal "Onetime::BackfillMembershipRenewalReminders::LeaseLost", error.class.name

    assert_sidekiq_enqueued(RecurringChargeReminderWorker, args: [first.id])
    assert_not RecurringChargeReminderWorker.jobs.any? { |j| j["args"] == [second.id] }
    assert_other_run_untouched
  end

  test "a run that lost its lease while a row failed records no attempt or progress" do
    subscription = create_eligible_subscription
    RecurringChargeReminderWorker.stub(:perform_at, lambda { |*_args|
      take_over_lease
      raise Redis::CannotConnectError
    }) do
      error = assert_raises(StandardError) { run_backfill }
      assert_equal "Onetime::BackfillMembershipRenewalReminders::LeaseLost", error.class.name
    end

    assert_nil $redis.hget(ATTEMPTS_KEY, subscription.id.to_s)
    assert_other_run_untouched
  end

  test "schedules the reminder for a membership whose refunded charge is still followed by a renewal charge" do
    subscription = create_eligible_subscription
    purchase = subscription.original_purchase
    charges_at = purchase.succeeded_at + subscription.period

    travel_to(purchase.succeeded_at + 1.day) do
      assert purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -purchase.total_transaction_cents), purchase.seller_id)
      summary = run_backfill

      assert_equal 1, summary[:scheduled]
      assert_sidekiq_enqueued(RecurringChargeReminderWorker, args: [subscription.id], at: charges_at - BasePrice::Recurrence.renewal_reminder_email_days(subscription.recurrence))
    end
  end

  test "counts an enqueue that returns no job id as an error, not as scheduled" do
    create_eligible_subscription
    RecurringChargeReminderWorker.stubs(:perform_at).returns(nil)

    summary = run_backfill

    assert_equal 0, summary[:scheduled]
    assert_equal 1, summary[:errors]
  end
end
