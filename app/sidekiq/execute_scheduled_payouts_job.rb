# frozen_string_literal: true

class ExecuteScheduledPayoutsJob
  include Sidekiq::Job
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
