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

  def perform(purchase_ids = nil)
    Purchase::UnstickStuckInProgressService.process(dry_run: false, ids: purchase_ids)
  end
end
