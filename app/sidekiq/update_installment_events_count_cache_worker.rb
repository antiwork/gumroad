# frozen_string_literal: true

class UpdateInstallmentEventsCountCacheWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed

  def perform(installment_id)
    installment = Installment.find(installment_id)
    total = installment.installment_events.count
    # This is a hot-fix for https://gumroad.slack.com/archives/C5Z7LG6Q1/p1583131085132100
    # TODO: Remove the hot-fix and skip validation selectively.
    installment.update_column(:installment_events_count, total)
  end
end
