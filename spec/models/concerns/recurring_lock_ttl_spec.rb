# frozen_string_literal: true

require "spec_helper"

# Namespaced jobs (app/sidekiq/reports/*) declare `module Reports` then `class FooJob`, so the class
# name has to be rebuilt from both rather than read off the `class` line alone — otherwise such a job
# never matches a schedule entry and is silently skipped by the coverage guard. Shared by the
# detector and the resolvability check so the two cannot drift.
module UntilExecutedJobName
  def self.call(source)
    klass = source[/^\s*class\s+([A-Za-z0-9_:]+)/, 1]
    return nil unless klass

    (source.scan(/^\s*module\s+([A-Za-z0-9_:]+)/).flatten + [klass]).join("::")
  end
end

describe UntilExecutedJobName do
  it "qualifies a namespaced job with its module" do
    source = "module Reports\n  class GenerateYtdSalesReportJob\n  end\nend\n"

    expect(described_class.call(source)).to eq("Reports::GenerateYtdSalesReportJob")
  end

  it "returns a top-level job's name unchanged" do
    expect(described_class.call("class FightDisputesJob\nend\n")).to eq("FightDisputesJob")
  end
end

describe RecurringLockTtl do
  # A scheduled `until_executed` job has a constant lock digest — MD5(class, queue, lock_args), and
  # a cron entry enqueues the same args every fire — so a SIGKILL that strands the lock mutes every
  # later enqueue forever, arguments or not. This is the guard that keeps the next such job from
  # being born with the hole rather than a list of the ones fixed today.
  describe "every scheduled until_executed job" do
    def self.until_executed_job_sources
      Dir[Rails.root.join("app/sidekiq/**/*.rb")].filter_map do |path|
        source = File.read(path)
        [path, source] if source.include?("lock: :until_executed")
      end
    end

    def self.scheduled_until_executed_jobs
      schedule = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml"))
      scheduled = schedule.each_value.filter_map { |e| e["class"] if e.is_a?(Hash) && e["cron"].present? }.uniq

      until_executed_job_sources.filter_map do |_path, source|
        klass = UntilExecutedJobName.call(source)
        klass if klass && scheduled.include?(klass)
      end
    end

    # Held in locals, not re-called per example: `def self.` methods are group scope, and reaching
    # for one inside an `it` raises rather than resolving.
    job_sources = until_executed_job_sources
    covered_jobs = scheduled_until_executed_jobs

    covered_jobs.each do |klass|
      context klass do
        let(:job) { klass.constantize }
        let(:ttl) { job.sidekiq_options["lock_ttl"] }
        let(:max_attempt) { job.try(:recurring_lock_max_attempt) }
        let(:interval) { RecurringLockTtl.schedule_interval_for(klass) }

        it "bounds its lock so a stranded digest cannot mute it forever" do
          expect(ttl).to be_present,
                         "#{klass} is scheduled and locks :until_executed, so its digest is " \
                         "constant per schedule entry and one SIGKILL silently drops every later " \
                         "enqueue. Add `include RecurringLockTtl` and " \
                         "`recurring_lock_ttl max_attempt: <worst case>`."
          expect(ttl).to be_positive
        end

        # The safety bound, asserted against the job's own declared worst case rather than against
        # SAFETY_MARGIN — every TTL clears the margin trivially, so that comparison pins nothing.
        # Breaking this expires the lock under a live attempt and lets the next enqueue run a second
        # copy concurrently.
        it "keeps the ttl above its declared worst-case attempt" do
          expect(max_attempt).to be_present,
                                 "#{klass} sets lock_ttl without going through RecurringLockTtl, " \
                                 "so nothing relates its TTL to a declared worst-case attempt."
          expect(ttl.seconds).to be > max_attempt
        end

        # The real serialization invariant. Because the ceiling forces TTL below the interval, the
        # lock is always expired before the next cron fires — so what actually keeps two copies from
        # overlapping is the attempt finishing inside its interval, not the lock. A declaration that
        # breaks this is a job we expect to overlap itself.
        it "declares a worst-case attempt that fits inside its schedule interval" do
          skip "interval is shorter than any survivable attempt" if interval && interval < 15.minutes

          expect(max_attempt + RecurringLockTtl::SAFETY_MARGIN).to be < interval if interval
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
      expect(covered_jobs.size).to be >= 28
    end

    it "resolves every until_executed job's class name" do
      # The detector's only silent-skip path: a file whose class name cannot be rebuilt is dropped
      # without ever being checked for a TTL. Asserting the set is empty means a new file shape
      # fails here rather than quietly leaving a job unguarded.
      unresolvable = job_sources.filter_map do |path, source|
        name = UntilExecutedJobName.call(source)
        path.to_s unless name&.safe_constantize
      end

      expect(unresolvable).to be_empty
    end
  end

  describe ".interval_of" do
    it "reports the real gap for a daily cron" do
      expect(RecurringLockTtl.interval_of("0 8 * * *")).to eq(24.hours)
    end

    it "reports an hourly cron" do
      expect(RecurringLockTtl.interval_of("0 * * * *")).to eq(1.hour)
    end

    # The reason the zone is pinned to UTC: sidekiq-scheduler fires these in UTC, but fugit evaluates
    # an unzoned expression in the host zone, where a DST transition makes one weekly gap 167h and
    # drags a TTL below the real interval.
    it "reports a weekly cron independently of the host timezone" do
      original = ENV["TZ"]
      begin
        ENV["TZ"] = "America/New_York"
        expect(RecurringLockTtl.interval_of("0 14 * * 5")).to eq(7.days)
      ensure
        ENV["TZ"] = original
      end
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

  describe ".recurring_lock_ttl" do
    # A non-positive declaration yields a TTL at or below the safety margin, and lock.lua skips the
    # PEXPIRE entirely for a negative pttl — silently restoring the unbounded lock this exists to
    # remove.
    it "refuses a non-positive worst-case attempt" do
      job = Class.new do
        include Sidekiq::Job
        include RecurringLockTtl
      end

      expect { job.recurring_lock_ttl max_attempt: 0.seconds }.to raise_error(ArgumentError)
      expect { job.recurring_lock_ttl max_attempt: -1.minute }.to raise_error(ArgumentError)
    end
  end
end
