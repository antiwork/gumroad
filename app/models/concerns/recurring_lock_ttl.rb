# frozen_string_literal: true

# Bounds how long an `until_executed` lock can survive its own job.
#
# A SIGKILL (OOM, deploy reap) skips the `ensure` that releases the lock. A job taking no
# arguments has a constant digest, so one strand makes every later enqueue hash to a held
# digest and get dropped by the client middleware — no exception, no dead set, cron still
# reporting success. `ScheduleAbandonedCartEmailsJob` was muted platform-wide for seven days
# that way (gumroad-private#1576). The death handler in the Sidekiq initializer only fires on
# retry exhaustion, so it never sees a killed process.
#
# Two bounds apply, and they are not symmetric:
#
#   TTL > worst-case attempt   — safety. Breaking it expires the lock under a live attempt and
#                                lets the next enqueue run a second copy concurrently. On the
#                                payout jobs that means paying a seller twice, which is worse
#                                than the outage this exists to prevent.
#   TTL < schedule interval    — recovery. Keeps a strand costing one run instead of every run.
#
# The second is best-effort. `DispatchPendingFailedRefundExceptionsJob` runs every 60 seconds
# and cannot finish in less, so no TTL satisfies both — safety wins and the outage is bounded
# by the TTL rather than by the interval. Turning "forever" into "minutes" is the point;
# "one run" is the bonus where the schedule allows it.
module RecurringLockTtl
  extend ActiveSupport::Concern

  # Covers the gap between the lock's PEXPIRE at acquisition and the attempt actually starting,
  # plus Redis/Rails clock skew.
  SAFETY_MARGIN = 5.minutes

  # Recovery target: aim to release a strand after a few worst-case attempts rather than sitting
  # on the schedule interval, which on a monthly job would be a month.
  ATTEMPT_MULTIPLE = 3

  class_methods do
    # `max_attempt` is the worst-case runtime of one attempt and is a judgement call per job, not
    # something derivable — it is required for that reason. The interval comes from the job's own
    # cron so it cannot drift out of sync with the schedule the way a copied constant would.
    def recurring_lock_ttl(max_attempt:)
      ttl = RecurringLockTtl.ttl_for(name, max_attempt:)
      sidekiq_options lock_ttl: ttl.to_i
      ttl
    end
  end

  def self.ttl_for(job_class_name, max_attempt:)
    floor = max_attempt + SAFETY_MARGIN
    interval = schedule_interval_for(job_class_name)
    ceiling = interval ? [interval - SAFETY_MARGIN, floor].max : floor

    [max_attempt * ATTEMPT_MULTIPLE, floor].max.clamp(floor, ceiling)
  end

  # nil when the job has no cron entry. Returning nil rather than raising keeps a schedule edit
  # from breaking boot; the ttl then falls back to the safety floor, which is finite and above the
  # attempt, and `spec/models/concerns/recurring_lock_ttl_spec.rb` fails in CI so it does not go
  # unnoticed.
  def self.schedule_interval_for(job_class_name)
    crons = schedule_crons[job_class_name]
    return nil if crons.blank?

    crons.filter_map { |cron| interval_of(cron) }.min
  end

  def self.schedule_crons
    @schedule_crons ||= YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml"))
                            .each_value
                            .with_object(Hash.new { |h, k| h[k] = [] }) do |entry, acc|
      next unless entry.is_a?(Hash) && entry["class"].present? && entry["cron"].present?
      acc[entry["class"]] << entry["cron"]
    end
  end

  # Sampled over consecutive fire times rather than read off the expression, so an irregular cron
  # ("0 9 * * 1-5") reports its shortest real gap instead of a nominal period. The shortest gap is
  # the one that matters: it is the soonest a strand could block a run.
  #
  # `to_utc_time`, not `to_t` — the latter returns system-local time, which shifts every gap by the
  # UTC offset and silently reports a daily job's interval as 13h on a UTC-4 host.
  SAMPLES = 12

  def self.interval_of(cron)
    parsed = Fugit.parse_cron(cron)
    return nil if parsed.nil?

    # Start from the first fire, not from an arbitrary instant: the gap between the cursor and the
    # first fire is a partial period and would drag the minimum below the real interval.
    cursor = parsed.next_time(Time.utc(2026, 1, 5)).to_utc_time # a Monday, so weekday crons fire
    gaps = SAMPLES.times.map do
      nxt = parsed.next_time(cursor).to_utc_time
      gap = nxt - cursor
      cursor = nxt
      gap
    end

    gaps.min.seconds
  end
end
