# frozen_string_literal: true

# Re-issues payouts that failed for a reason of ours rather than the seller's — a processor rate
# limit (HTTP 429) or an unreachable processor.
#
# Those failures are terminal today: the payment is marked failed, the balance goes back to
# `unpaid`, and the seller waits for their next scheduled slot. For a monthly-cadence seller that
# turns a few seconds of Stripe rate limiting into a four-week payout delay (gumroad-private#1523:
# 32 sellers, $15.4K, all reissued by hand).
#
# Running hours after the batch is the backoff: the burst that earned the 429 is long over, and
# the requeue goes through the normal payout path, so every eligibility, compliance and pause
# check applies again.
class RequeueTransientlyFailedPayoutsJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :critical, lock: :until_executed

  # Two requeues per payout period. A seller who keeps hitting transient failures is no longer
  # looking like a burst we can wait out, and reissuing all week only produces more failed rows;
  # past the cap the payout waits for its next scheduled slot and the exhaustion is reported.
  MAX_REQUEUE_ATTEMPTS = 2

  def perform
    payout_period_end_date = User::PayoutSchedule.next_scheduled_payout_end_date

    failures_by_user = Payment.failed
                              .reorder(nil)
                              .processed_by(PayoutProcessorType::STRIPE)
                              .where(failure_reason: Payment::FailureReason::TRANSIENT_REASONS, payout_period_end_date:)
                              .group(:user_id)
                              .count
    return if failures_by_user.empty?

    user_ids, exhausted_user_ids = failures_by_user.keys.partition { |user_id| failures_by_user[user_id] <= MAX_REQUEUE_ATTEMPTS }

    if exhausted_user_ids.present?
      ErrorNotifier.notify(
        "Payouts: #{exhausted_user_ids.size} seller(s) hit #{MAX_REQUEUE_ATTEMPTS} transient payout failures for #{payout_period_end_date} and were not requeued",
        payout_period_end_date: payout_period_end_date.to_s,
        user_ids: exhausted_user_ids
      )
    end
    return if user_ids.empty?

    Rails.logger.info("REQUEUE TRANSIENTLY FAILED PAYOUTS: #{payout_period_end_date}, #{user_ids.size} seller(s) (Started)")

    # `retrying: true` skips the payout-cycle gate. A failed payout moves the seller's next cycle
    # forward, so the gate would reject the very sellers this job exists for. Re-issuing is
    # otherwise safe: Payouts.create_payment no-ops once the balances have left `unpaid`, so a
    # seller already paid since the failure is not paid twice.
    Payouts.create_payments_for_balances_up_to_date_for_users(
      payout_period_end_date,
      PayoutProcessorType::STRIPE,
      User.where(id: user_ids),
      perform_async: true,
      retrying: true
    )

    Rails.logger.info("REQUEUE TRANSIENTLY FAILED PAYOUTS: #{payout_period_end_date} (Finished)")
  end
end
