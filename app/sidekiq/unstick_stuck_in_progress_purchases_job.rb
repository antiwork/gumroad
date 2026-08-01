# frozen_string_literal: true

# Scheduled half of Purchase::UnstickStuckInProgressService.
#
# SyncStuckPurchasesJob gives up on anything older than 3 days, so this runs daily over the 3–90 day
# window to catch purchases that were charged but never delivered, and alerts on whatever it still
# cannot heal. Pass ids to re-run it by hand over a specific set after an incident; that form ignores
# the age bounds, so it also reaches rows that have aged past the scheduled window.
class UnstickStuckInProgressPurchasesJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed
  include RecurringLockTtl
  # Walks the 3-90 day in_progress window once a day and re-checks each row against the charge
  # processor, so the attempt scales with the backlog rather than with a fixed page. An hour is
  # well past anything observed and still leaves the daily interval a wide margin.
  recurring_lock_ttl max_attempt: 1.hour

  def perform(purchase_ids = nil)
    Purchase::UnstickStuckInProgressService.process(dry_run: false, ids: purchase_ids)
  end
end
