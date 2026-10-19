# frozen_string_literal: true

require "test_helper"

class Onetime::BackfillMembershipAdvanceRenewalRemindersTest < ActiveSupport::TestCase
  CURSOR_KEY = Onetime::BackfillMembershipAdvanceRenewalReminders::CURSOR_KEY
  RUNNING_KEY = Onetime::BackfillMembershipAdvanceRenewalReminders::RUNNING_KEY
  ATTEMPTS_KEY = Onetime::BackfillMembershipAdvanceRenewalReminders::ATTEMPTS_KEY
  FAILED_IDS_KEY = Onetime::BackfillMembershipAdvanceRenewalReminders::FAILED_IDS_KEY

  setup do
    $redis.del(CURSOR_KEY, RUNNING_KEY, ATTEMPTS_KEY, FAILED_IDS_KEY)
    Feature.activate(:membership_renewal_reminders)
  end

  teardown do
    Feature.deactivate(:membership_renewal_reminders)
    $redis.del(CURSOR_KEY, RUNNING_KEY, ATTEMPTS_KEY, FAILED_IDS_KEY)
    RecurringChargeReminderWorker.clear
  end

  def run_backfill(deployed_at: 1.minute.from_now, **opts)
    Onetime::BackfillMembershipAdvanceRenewalReminders.process(deployed_at:, **opts)
  end

  def create_subscription_for_backfill(recurrence: BasePrice::Recurrence::YEARLY)
    product = create_membership_product(user: create_user)
    subscription = create_subscription(link: product)
    create_membership_purchase(link: product, subscription:)
    RecurringChargeReminderWorker.clear
    subscription.reload
    Subscription.any_instance.stubs(:recurrence).returns(recurrence)
    Subscription.any_instance.stubs(:end_time_of_subscription).returns(60.days.from_now)
    subscription
  end

  test "schedules the advance notice for a yearly subscription bought before the deploy" do
    subscription = create_subscription_for_backfill

    summary = run_backfill

    job = RecurringChargeReminderWorker.jobs.find { |j| j["args"] == [subscription.id, RecurringChargeReminderWorker::ADVANCE] }
    assert job
    assert_in_delta 30.days.from_now.to_f, job["at"], 5
    assert_equal 1, summary[:scheduled]
  end

  test "covers a subscription bought after the old reminder backfill cutoff" do
    create_subscription_for_backfill

    summary = run_backfill

    assert_equal 1, summary[:scheduled]
  end

  test "skips periods under 12 months" do
    create_subscription_for_backfill(recurrence: BasePrice::Recurrence::MONTHLY)

    assert_equal 0, run_backfill[:scheduled]
  end

  test "skips a subscription whose own purchase already scheduled the notice" do
    create_subscription_for_backfill

    assert_equal 0, run_backfill(deployed_at: 1.minute.ago)[:scheduled]
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
end
