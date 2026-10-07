# frozen_string_literal: true

class FreeTrialExpiringReminderWorker
  class EmailNotEnqueuedError < StandardError; end

  include Sidekiq::Job
  sidekiq_options retry: 3,
                  queue: :default,
                  lock: :while_executing,
                  lock_timeout: 2,
                  unique_across_queues: true,
                  on_conflict: { server: :raise }

  def perform(subscription_id)
    # A cold worker replica can still be missing the preceding worker's completed marker.
    ApplicationRecord.connected_to(role: :writing) do
      subscription = Subscription.find(subscription_id)
      return unless subscription.alive?(include_pending_cancellation: false) &&
                    subscription.in_free_trial? &&
                    !(subscription.renewal_disabled_due_to_indian_card_mandate? && subscription.india_card_mandate_reliability_enabled?) &&
                    !subscription.is_test_subscription?

      digest = SentEmailInfo.mailer_key_digest("CustomerLowPriorityMailer", "free_trial_expiring_soon", subscription_id)
      return if SentEmailInfo.key_exists?(digest)

      # A failed enqueue must remain retryable; a crash before the marker can duplicate one notice.
      enqueued = CustomerLowPriorityMailer.free_trial_expiring_soon(subscription_id).deliver_later(queue: "low")
      raise EmailNotEnqueuedError, "Free-trial expiry reminder was not enqueued" unless enqueued

      SentEmailInfo.set_key!(digest)
    end
  end
end
