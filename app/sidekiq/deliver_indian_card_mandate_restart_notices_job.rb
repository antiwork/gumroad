# frozen_string_literal: true

# Retries the buyer notices of a held Indian-mandate restart that could not be delivered when it was decided.
class DeliverIndianCardMandateRestartNoticesJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 5, lock: :until_executed

  RETRY_DELAY = 5.minutes

  # A failed enqueue leaves the markers set; FindSubscriptionsWithMissingChargeWorker re-enqueues this job for any
  # membership still owing one.
  def self.schedule_retry(subscription_id)
    perform_in(RETRY_DELAY, subscription_id)
  rescue StandardError => e
    ErrorNotifier.notify(e, subscription_id:)
  end

  def perform(subscription_id)
    Subscription.find_by(id: subscription_id)&.deliver_indian_card_mandate_restart_notices!
  end
end
