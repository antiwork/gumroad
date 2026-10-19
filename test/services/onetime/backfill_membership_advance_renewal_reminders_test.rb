# frozen_string_literal: true

require "test_helper"

class Onetime::BackfillMembershipAdvanceRenewalRemindersTest < ActiveSupport::TestCase
  CURSOR_KEY = Onetime::BackfillMembershipAdvanceRenewalReminders::CURSOR_KEY
  RUNNING_KEY = Onetime::BackfillMembershipAdvanceRenewalReminders::RUNNING_KEY
  ROLLOUT_FINISHED_AT = Time.utc(2026, 11, 2, 15).freeze

  setup do
    $redis.del(CURSOR_KEY, RUNNING_KEY)
    Feature.activate(:membership_renewal_reminders)
  end

  teardown do
    travel_back
    Feature.deactivate(:membership_renewal_reminders)
    $redis.del(CURSOR_KEY, RUNNING_KEY)
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

  test "a dry run schedules nothing and a rerun after a finished run is a no-op" do
    create_subscription_for_backfill

    assert_equal 0, run_backfill(dry_run: true)[:scheduled]
    assert_nil $redis.get(CURSOR_KEY)

    assert_equal 1, run_backfill[:scheduled]
    RecurringChargeReminderWorker.clear
    assert_equal 0, run_backfill[:considered]
  end

  test "treats an enqueue that returns no job id as a failure" do
    create_subscription_for_backfill
    RecurringChargeReminderWorker.stubs(:perform_at).returns(nil)

    summary = run_backfill

    assert_equal 1, summary[:errors]
    assert_equal 0, summary[:scheduled]
    assert_nil $redis.get(CURSOR_KEY)
  end

  test "rejects a cutoff that is not a past time before touching Redis" do
    create_subscription_for_backfill

    assert_raises(ArgumentError) { run_backfill(rollout_finished_at: ROLLOUT_FINISHED_AT.iso8601) }
    assert_raises(ArgumentError) { run_backfill(rollout_finished_at: 1.hour.from_now) }
    assert_nil $redis.get(RUNNING_KEY)
    assert_nil $redis.get(CURSOR_KEY)
    assert_empty RecurringChargeReminderWorker.jobs

    assert_equal 1, run_backfill(rollout_finished_at: ROLLOUT_FINISHED_AT.in_time_zone("America/New_York"))[:scheduled]
  end
end
