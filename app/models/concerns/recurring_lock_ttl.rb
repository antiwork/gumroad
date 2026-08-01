# frozen_string_literal: true

# Bounds how long an `until_executed` lock can survive its own job.
#
# A SIGKILL (OOM, deploy reap) skips the `ensure` that releases the lock. The digest is
# MD5(class, queue, lock_args), and a cron entry enqueues the same args every fire — so every
# scheduled job's digest is constant, arguments or not. One strand makes every later enqueue for
# that entry hash to a held digest and get dropped by the client middleware: no exception, no dead
# set, cron still reporting success. The death handler in the Sidekiq initializer only fires on
# retry exhaustion, so it never sees a killed process, and `on_conflict: :replace` does not rescue
# it either (it deletes a *queued* duplicate; in this scenario the original was running).
#
# Two bounds apply, and they are not symmetric:
#
#   TTL > worst-case attempt   — bounds how long a live attempt runs unlocked. The lock is
#                                PEXPIREd by the client middleware at ENQUEUE and the server
#                                never refreshes it, so an attempt begins with
#                                `TTL - queue_latency` remaining, not TTL. This bound therefore
#                                shrinks the unlocked window; it cannot close it.
#   TTL < schedule interval    — recovery. Keeps a strand costing one run instead of every run.
#
# The second is best-effort. `DispatchPendingFailedRefundExceptionsJob` runs every 60 seconds and
# cannot finish in less, so no TTL satisfies both — safety wins and the outage is bounded by the
# TTL rather than by the interval.
#
# Because the ceiling forces TTL ≤ interval − margin, the lock is always expired by the time the
# next cron fires, so for cron-driven enqueues the lock is not what serializes runs — the attempt
# finishing inside its interval is. `max_attempt` must therefore stay below the interval, which
# `spec/models/concerns/recurring_lock_ttl_spec.rb` asserts per job.
module RecurringLockTtl
  extend ActiveSupport::Concern

  # Covers the gap between the lock's PEXPIRE at acquisition and the attempt actually starting,
  # plus Redis/Rails clock skew.
  SAFETY_MARGIN = 5.minutes

  # Recovery target: aim to release a strand after a few worst-case attempts rather than sitting
  # on the schedule interval, which on a monthly job would be a month.
  ATTEMPT_MULTIPLE = 3

  included do
    # Read back by the spec to assert the safety bound against the declared figure rather than
    # against the margin, which every TTL clears trivially.
    class_attribute :recurring_lock_max_attempt, instance_writer: false
  end

  class_methods do
    # `max_attempt` is the worst-case runtime of one attempt and is a judgement call per job, not
    # something derivable — it is required for that reason. The interval comes from the job's own
    # cron so it cannot drift out of sync with the schedule the way a copied constant would.
    def recurring_lock_ttl(max_attempt:)
      raise ArgumentError, "max_attempt must be positive" unless max_attempt.positive?

      self.recurring_lock_max_attempt = max_attempt
      sidekiq_options lock_ttl: RecurringLockTtl.ttl_for(name, max_attempt:).to_i
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
  #
  # A class scheduled under several entries takes the shortest gap of any of them. Digests are
  # per-(class, args) so each entry strands independently, and the shortest gap is the tightest
  # ceiling — which is the safe direction for recovery.
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
  # The zone is pinned to UTC rather than left to the host: sidekiq-scheduler evaluates these
  # expressions in UTC in production, and on a host in a DST-observing zone the gap across a
  # transition is 23h or 25h, so an unpinned weekly cron reports 167h and a TTL derived from it
  # drifts under the real interval.
  SAMPLES = 12

  def self.interval_of(cron)
    # Every expression in the schedule is a bare 5-field cron; only pin the zone when one has not
    # been given, so a future entry carrying its own zone is honoured rather than mangled.
    parsed = Fugit.parse_cron(cron.split.size == 5 ? "#{cron} UTC" : cron)
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
