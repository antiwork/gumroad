# frozen_string_literal: true

require "spec_helper"

describe RecurringLockTtl do
  # A no-argument `until_executed` job has a constant lock digest, so a SIGKILL that strands the
  # lock mutes every later enqueue forever. This is the guard that keeps the next such job from
  # being born with the hole rather than a list of the ones fixed today.
  describe "every no-arg scheduled until_executed job" do
    def self.no_arg_until_executed_scheduled_jobs
      schedule = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml"))
      scheduled = schedule.each_value.filter_map { |e| e["class"] if e.is_a?(Hash) && e["cron"].present? }.uniq

      Dir[Rails.root.join("app/sidekiq/**/*.rb")].filter_map do |path|
        source = File.read(path)
        next unless source.include?("lock: :until_executed")

        klass = source[/^\s*class\s+([A-Za-z0-9_:]+)/, 1]
        next unless klass && scheduled.include?(klass)
        next unless klass.constantize.instance_method(:perform).arity.zero?

        klass
      end
    end

    no_arg_until_executed_scheduled_jobs.each do |klass|
      context klass do
        let(:job) { klass.constantize }
        let(:ttl) { job.sidekiq_options["lock_ttl"] }
        let(:interval) { RecurringLockTtl.schedule_interval_for(klass) }

        it "bounds its lock so a stranded digest cannot mute it forever" do
          expect(ttl).to be_present,
                         "#{klass} takes no arguments and locks :until_executed, so one SIGKILL " \
                         "strands a constant digest and silently drops every later enqueue. " \
                         "Add `include RecurringLockTtl` and `recurring_lock_ttl max_attempt: <worst case>`."
          expect(ttl).to be_positive
        end

        # The safety bound. Breaking it expires the lock under a live attempt and lets the next
        # enqueue run a second copy concurrently — on the payout jobs, paying a seller twice.
        it "keeps the ttl above one worst-case attempt" do
          expect(ttl.seconds).to be > RecurringLockTtl::SAFETY_MARGIN
        end

        # The recovery bound, asserted as an ordering rather than a literal so rescheduling the job
        # moves the assertion with it. Best-effort: a job whose interval is shorter than any
        # survivable attempt cannot satisfy it, and safety wins there.
        it "releases a stranded lock within one schedule interval where the schedule allows it" do
          skip "interval is shorter than any survivable attempt" if interval && interval < 15.minutes

          expect(ttl.seconds).to be <= interval if interval
        end
      end
    end

    it "covers a non-trivial number of jobs" do
      # A refactor that makes the detector match nothing would turn every example above into a
      # vacuous pass, and the suite would stay green over an unguarded fleet.
      expect(no_arg_until_executed_scheduled_jobs.size).to be >= 15
    end
  end

  describe ".interval_of" do
    it "reports the real gap for a daily cron regardless of host timezone" do
      expect(RecurringLockTtl.interval_of("0 8 * * *")).to eq(24.hours)
    end

    it "reports an hourly cron" do
      expect(RecurringLockTtl.interval_of("0 * * * *")).to eq(1.hour)
    end

    it "reports a weekly cron" do
      expect(RecurringLockTtl.interval_of("0 14 * * 5")).to eq(7.days)
    end

    # The reason gaps are sampled rather than derived from the expression: a weekday-restricted
    # cron's shortest gap is a day, not the week its expression suggests.
    it "reports the shortest gap for an irregular cron" do
      expect(RecurringLockTtl.interval_of("0 9 * * 1-5")).to eq(24.hours)
    end

    it "returns nil for an unparseable expression" do
      expect(RecurringLockTtl.interval_of("not a cron")).to be_nil
    end
  end

  describe ".ttl_for" do
    it "sits above the attempt and under the interval when the schedule allows both" do
      ttl = RecurringLockTtl.ttl_for("PerformDailyInstantPayoutsWorker", max_attempt: 3.hours)

      expect(ttl).to be > 3.hours
      expect(ttl).to be < RecurringLockTtl.schedule_interval_for("PerformDailyInstantPayoutsWorker")
    end

    it "keeps the ttl above the attempt even when the interval is shorter" do
      ttl = RecurringLockTtl.ttl_for("DispatchPendingFailedRefundExceptionsJob", max_attempt: 10.minutes)

      expect(ttl).to be > 10.minutes
    end

    it "falls back to the safety floor for a job with no cron entry" do
      ttl = RecurringLockTtl.ttl_for("NotScheduledAnywhereJob", max_attempt: 30.minutes)

      expect(ttl).to eq(30.minutes + RecurringLockTtl::SAFETY_MARGIN)
    end
  end
end
