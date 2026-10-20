# frozen_string_literal: true

require "test_helper"

class Onetime::BackfillMembershipAdvanceRenewalRemindersTest < ActiveSupport::TestCase
  CURSOR_KEY = Onetime::BackfillMembershipAdvanceRenewalReminders::CURSOR_KEY
  RUNNING_KEY = Onetime::BackfillMembershipAdvanceRenewalReminders::RUNNING_KEY
  ATTEMPTS_KEY = Onetime::BackfillMembershipAdvanceRenewalReminders::ATTEMPTS_KEY
  FAILED_IDS_KEY = Onetime::BackfillMembershipAdvanceRenewalReminders::FAILED_IDS_KEY
  ROLLOUT_FINISHED_AT = Time.utc(2026, 11, 2, 15).freeze

  setup do
    $redis.del(CURSOR_KEY, RUNNING_KEY, ATTEMPTS_KEY, FAILED_IDS_KEY)
    Feature.activate(:membership_renewal_reminders)
  end

  teardown do
    travel_back
    Feature.deactivate(:membership_renewal_reminders)
    $redis.del(CURSOR_KEY, RUNNING_KEY, ATTEMPTS_KEY, FAILED_IDS_KEY)
    RecurringChargeReminderWorker.clear
  end

  def run_backfill(rollout_finished_at: ROLLOUT_FINISHED_AT, **opts)
    Onetime::BackfillMembershipAdvanceRenewalReminders.process(rollout_finished_at:, **opts)
  end

  def create_subscription_for_backfill(recurrence: BasePrice::Recurrence::YEARLY, purchased_at: ROLLOUT_FINISHED_AT - 1.day)
    subscription = travel_to(purchased_at) do
      product = create_membership_product(user: create_user)
      create_subscription(link: product).tap { create_membership_purchase(link: product, subscription: _1) }
    end
    travel_to(ROLLOUT_FINISHED_AT + 1.hour)
    RecurringChargeReminderWorker.clear
    Subscription.any_instance.stubs(:recurrence).returns(recurrence)
    Subscription.any_instance.stubs(:end_time_of_subscription).returns(60.days.from_now)
    subscription.reload
  end

  def advance_jobs
    RecurringChargeReminderWorker.jobs.select { _1["args"].last == RecurringChargeReminderWorker::ADVANCE }
  end

  test "schedules the advance notice for a yearly subscription bought before the rollout finished" do
    subscription = create_subscription_for_backfill

    summary = run_backfill

    job = advance_jobs.sole
    assert_equal [subscription.id, RecurringChargeReminderWorker::ADVANCE], job["args"]
    assert_in_delta 30.days.from_now.to_f, job["at"], 5
    assert_equal 1, summary[:scheduled]
  end

  test "covers a subscription bought after the old reminder backfill's cutoff" do
    create_subscription_for_backfill(purchased_at: Onetime::BackfillMembershipRenewalReminders::FLAG_ENABLED_AT + 1.week)

    assert_equal 1, run_backfill[:scheduled]
  end

  test "skips periods under 12 months" do
    create_subscription_for_backfill(recurrence: BasePrice::Recurrence::MONTHLY)

    assert_equal 0, run_backfill[:scheduled]
  end

  test "skips a subscription bought after the rollout finished, whose own purchase scheduled the notice" do
    create_subscription_for_backfill(purchased_at: ROLLOUT_FINISHED_AT + 1.minute)

    assert_equal 0, run_backfill[:scheduled]
  end

  test "skips an advance time that has already passed" do
    create_subscription_for_backfill
    Subscription.any_instance.stubs(:end_time_of_subscription).returns(20.days.from_now)

    assert_equal 0, run_backfill[:scheduled]
  end

  test "stops at a row whose scheduling raises so the next run retries it" do
    first = create_subscription_for_backfill
    second = create_subscription_for_backfill

    calls = 0
    RecurringChargeReminderWorker.stub(:perform_at, lambda { |*_args|
      calls += 1
      raise "enqueue failed" if calls == 2
      "jid"
    }) do
      summary = run_backfill

      assert_equal 1, summary[:errors]
      assert_equal 1, summary[:scheduled]
      assert_equal first.id.to_s, $redis.get(CURSOR_KEY)
    end

    # The failed subscription is still ahead of the cursor, so a later run retries it.
    assert_operator $redis.get(CURSOR_KEY).to_i, :<, second.id
    scheduled_ids = []
    RecurringChargeReminderWorker.stub(:perform_at, ->(at, id, kind) { scheduled_ids << [id, kind] }) do
      run_backfill
    end
    assert_includes scheduled_ids.map(&:first), [first.id, second.id].max
  end

  test "schedules nothing past a failed row in the same run" do
    first = create_subscription_for_backfill
    second = create_subscription_for_backfill
    create_subscription_for_backfill
    enqueue = RecurringChargeReminderWorker.method(:perform_at)
    RecurringChargeReminderWorker.stub(:perform_at, ->(at, id, *args) { id == second.id ? nil : enqueue.call(at, id, *args) }) do
      run_backfill
    end

    assert_equal first.id.to_s, $redis.get(CURSOR_KEY)
    assert_equal [first.id], RecurringChargeReminderWorker.jobs.map { _1["args"].first }
  end

  test "a row that keeps failing is stepped over instead of stalling every subscription after it" do
    bad = create_subscription_for_backfill
    good = create_subscription_for_backfill
    scheduled_ids = []

    RecurringChargeReminderWorker.stub(:perform_at, lambda { |_at, id, kind|
      raise "bad row" if id == bad.id

      scheduled_ids << id
    }) do
      # The production cap is 3; hard-coded so mutating the constant cannot spin this loop.
      3.times do |attempt|
        summary = run_backfill
        assert_equal 1, summary[:errors]
        # Every run before the last attempt stops before the failing row.
        assert_operator $redis.get(CURSOR_KEY).to_i, :<, bad.id if attempt < 2
      end

      assert_includes $redis.smembers(FAILED_IDS_KEY).map(&:to_i), bad.id
      assert_operator $redis.get(CURSOR_KEY).to_i, :>=, bad.id
      assert_includes scheduled_ids, good.id
    end
  end

  test "a dry run schedules nothing and a rerun after a finished run is a no-op" do
    create_subscription_for_backfill

    assert_equal 0, run_backfill(dry_run: true)[:scheduled]
    assert_nil $redis.get(CURSOR_KEY)

    assert_equal 1, run_backfill[:scheduled]
    RecurringChargeReminderWorker.clear
    assert_equal 0, run_backfill[:considered]
  end

  test "treats an enqueue that returns no job id as a failed attempt toward the cap" do
    subscription = create_subscription_for_backfill
    RecurringChargeReminderWorker.stubs(:perform_at).returns(nil)

    summary = run_backfill

    assert_equal 1, summary[:errors]
    assert_equal 0, summary[:scheduled]
    assert_nil $redis.get(CURSOR_KEY)
    assert_equal "1", $redis.hget(ATTEMPTS_KEY, subscription.id.to_s)

    2.times { run_backfill }
    assert_includes $redis.smembers(FAILED_IDS_KEY).map(&:to_i), subscription.id
    assert_equal subscription.id.to_s, $redis.get(CURSOR_KEY)
  end

  test "a dry run with a failing row leaves attempts, failed ids and the cursor untouched" do
    create_subscription_for_backfill
    RecurringChargeReminderWorker.stubs(:perform_at).raises(Redis::CannotConnectError)
    Subscription.any_instance.stubs(:advance_renewal_reminder_at).raises(Redis::CannotConnectError)

    summary = run_backfill(dry_run: true)

    assert_equal 1, summary[:errors]
    assert_nil $redis.get(CURSOR_KEY)
    assert_empty $redis.hgetall(ATTEMPTS_KEY)
    assert_empty $redis.smembers(FAILED_IDS_KEY)
  end

  test "a successful retry clears the row's attempt count" do
    subscription = create_subscription_for_backfill
    RecurringChargeReminderWorker.stubs(:perform_at).returns(nil)
    run_backfill
    assert_equal "1", $redis.hget(ATTEMPTS_KEY, subscription.id.to_s)

    RecurringChargeReminderWorker.unstub(:perform_at)
    assert_equal 1, run_backfill[:scheduled]
    assert_nil $redis.hget(ATTEMPTS_KEY, subscription.id.to_s)
    assert_empty $redis.smembers(FAILED_IDS_KEY)
  end

  # Simulates RUNNING_KEY expiring under this run and another run claiming it and saving its own cursor.
  def take_over_lease(ttl: 30)
    $redis.set(RUNNING_KEY, "other-run", ex: ttl)
    $redis.set(CURSOR_KEY, "999999")
  end

  def assert_other_run_untouched(ttl: 30)
    assert_equal "other-run", $redis.get(RUNNING_KEY)
    assert_operator $redis.ttl(RUNNING_KEY), :<=, ttl
    assert_equal "999999", $redis.get(CURSOR_KEY)
  end

  test "a run that lost its lease after a row stops without touching the new run's claim or cursor" do
    create_subscription_for_backfill
    create_subscription_for_backfill
    calls = 0
    RecurringChargeReminderWorker.stub(:perform_at, lambda { |*_args|
      calls += 1
      take_over_lease if calls == 1
      "jid"
    }) do
      error = assert_raises(StandardError) { run_backfill }
      assert_equal "Onetime::BackfillMembershipAdvanceRenewalReminders::LeaseLost", error.class.name
    end

    assert_equal 1, calls
    assert_other_run_untouched
  end

  test "a run that lost its lease while a row failed records no attempt, failed id or progress" do
    subscription = create_subscription_for_backfill
    $redis.hset(ATTEMPTS_KEY, subscription.id.to_s, Onetime::BackfillMembershipAdvanceRenewalReminders::MAX_ATTEMPTS_PER_ROW - 1)
    RecurringChargeReminderWorker.stub(:perform_at, lambda { |*_args|
      take_over_lease
      raise Redis::CannotConnectError
    }) do
      error = assert_raises(StandardError) { run_backfill }
      assert_equal "Onetime::BackfillMembershipAdvanceRenewalReminders::LeaseLost", error.class.name
    end

    assert_equal (Onetime::BackfillMembershipAdvanceRenewalReminders::MAX_ATTEMPTS_PER_ROW - 1).to_s, $redis.hget(ATTEMPTS_KEY, subscription.id.to_s)
    assert_empty $redis.smembers(FAILED_IDS_KEY)
    assert_other_run_untouched
  end

  test "a run that lost its lease before enqueuing a row does not enqueue it" do
    first = create_subscription_for_backfill
    second = create_subscription_for_backfill
    advance_at = 30.days.from_now
    Subscription.any_instance.stubs(:advance_renewal_reminder_at).with { take_over_lease if $redis.get(CURSOR_KEY) == first.id.to_s; true }.returns(advance_at)

    error = assert_raises(StandardError) { run_backfill }
    assert_equal "Onetime::BackfillMembershipAdvanceRenewalReminders::LeaseLost", error.class.name

    assert_equal [first.id], advance_jobs.map { _1["args"].first }
    assert_not_includes advance_jobs.map { _1["args"].first }, second.id
    assert_other_run_untouched
  end

  test "a finished run releases its own claim" do
    create_subscription_for_backfill

    run_backfill

    assert_nil $redis.get(RUNNING_KEY)
  end

  test "rejects a cutoff that is not a past time before touching Redis" do
    create_subscription_for_backfill

    assert_raises(ArgumentError) { run_backfill(rollout_finished_at: ROLLOUT_FINISHED_AT.iso8601) }
    assert_raises(ArgumentError) { run_backfill(rollout_finished_at: 1.hour.from_now) }
    assert_nil $redis.get(RUNNING_KEY)
    assert_nil $redis.get(CURSOR_KEY)
    assert_empty $redis.hgetall(ATTEMPTS_KEY)
    assert_empty $redis.smembers(FAILED_IDS_KEY)
    assert_empty RecurringChargeReminderWorker.jobs

    assert_equal 1, run_backfill(rollout_finished_at: ROLLOUT_FINISHED_AT.in_time_zone("America/New_York"))[:scheduled]
  end
end
