# frozen_string_literal: true

# Daily driver for the opened-no-click trigger. Each of these workflow emails waits its own
# `delayed_delivery_time` from each recipient's own open, so every published email gets its own
# scan; the scan is where that clock is read.
class ScheduleOpenedNoClickWorkflowEmailsJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  # The walk covers every published email of every opened-no-click workflow, so it reads in
  # batches rather than holding the whole set in memory.
  SCAN_BATCH_SIZE = 200

  def perform
    Installment.alive.published
      .joins(:workflow)
      .merge(Workflow.alive.opened_no_click_trigger)
      .find_in_batches(batch_size: SCAN_BATCH_SIZE) do |installments|
        installments.each { SendWorkflowEmailsToOpenedNonClickersJob.perform_async(_1.id) }
      end
  end
end
