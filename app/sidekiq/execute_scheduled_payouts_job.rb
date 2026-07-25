# frozen_string_literal: true

class ExecuteScheduledPayoutsJob
  include Sidekiq::Job
  # Runs at 09:00 UTC (5am ET), inside the window the old overnight deploy block covered, and
  # moves money: each execute! creates a payout. A deploy that recycles Sidekiq mid-run can
  # interrupt a payout as it is being created, so hold deploys for the length of the run.
  # See HoldsDeployWhileRunning.
  include HoldsDeployWhileRunning::ForWholePerform
  sidekiq_options retry: 1, queue: :low, lock: :until_executed

  def perform
    Rails.logger.info("ExecuteScheduledPayoutsJob: Started")

    ScheduledPayout.due.find_each do |scheduled_payout|
      scheduled_payout.execute!
    rescue => e
      ErrorNotifier.notify(e, context: { scheduled_payout_id: scheduled_payout.id })
      Rails.logger.error("ExecuteScheduledPayoutsJob: Failed to execute scheduled payout #{scheduled_payout.id}: #{e.message}")
    end

    Rails.logger.info("ExecuteScheduledPayoutsJob: Finished")
  end
end
