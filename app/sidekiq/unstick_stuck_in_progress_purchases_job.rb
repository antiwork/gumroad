# frozen_string_literal: true

# Scheduled half of Purchase::UnstickStuckInProgressService.
#
# SyncStuckPurchasesJob gives up on anything older than 3 days, so this runs daily over the whole
# 90-day tail to catch purchases that were charged but never delivered, and alerts on whatever it
# still cannot heal. Pass ids to re-run it by hand over a specific set after an incident.
class UnstickStuckInProgressPurchasesJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed

  def perform(purchase_ids = nil)
    Purchase::UnstickStuckInProgressService.process(dry_run: false, ids: purchase_ids)
  end
end
