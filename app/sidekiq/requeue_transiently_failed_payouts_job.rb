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
  # :default, not :critical — this only reads failed rows and enqueues PayoutUsersWorker (itself
  # on :default). Nothing here is latency-sensitive, and :critical is where buyer-facing receipts
  # live.
  sidekiq_options retry: 0, queue: :default, lock: :until_executed

  # Two requeues per payout period. A seller who keeps hitting transient failures is no longer
  # looking like a burst we can wait out, and reissuing all week only produces more failed rows;
  # past the cap the payout waits for its next scheduled slot and the exhaustion is reported.
  MAX_REQUEUE_ATTEMPTS = 2

  # Comfortably longer than a payout period, so every daily run against one period sees the marker.
  EXHAUSTION_REPORT_DEDUPE_WINDOW = 30.days

  def perform
    # Kill switch: this job moves money, and the failure mode it fixes (a delayed payout) is far
    # less bad than the one a bug here could cause. Flipping the flag stops requeues without a
    # deploy; sellers fall back to waiting for their next scheduled slot, which is today's behaviour.
    return if Feature.active?(:disable_transient_payout_failure_requeue)

    # This runs daily rather than only on the batch weekdays, because a cross-border payout
    # executes CROSS_BORDER_PAYOUT_DELAY after it is created — a Thursday requeue of a Tuesday
    # failure fails on Friday afternoon, past the last batch of the week. `manual_payout_end_date`
    # is what makes the weekend runs land on the closing period rather than the next one, which
    # nothing has failed on yet.
    payout_period_end_date = User::PayoutSchedule.manual_payout_end_date

    failures_by_user = Payment.failed
                              .reorder(nil)
                              .processed_by(PayoutProcessorType::STRIPE)
                              .where(failure_reason: Payment::FailureReason::REQUEUEABLE_REASONS, payout_period_end_date:)
                              .group(:user_id)
                              .count
    return if failures_by_user.empty?

    user_ids, exhausted_user_ids = failures_by_user.keys.partition { |user_id| failures_by_user[user_id] <= MAX_REQUEUE_ATTEMPTS }

    # Report each exhausted seller once per payout period. Counting cannot dedupe this: once a
    # seller is over the cap the job stops requeueing them, so their failure count stops growing and
    # any count-based condition stays true on every later run of the same period.
    newly_exhausted = exhausted_user_ids.reject do |user_id|
      $redis.exists?(RedisKey.transient_payout_requeue_exhaustion_reported(user_id, payout_period_end_date))
    end
    if newly_exhausted.present?
      ErrorNotifier.notify(
        "Payouts: #{newly_exhausted.size} seller(s) hit #{MAX_REQUEUE_ATTEMPTS} transient payout failures for #{payout_period_end_date} and will wait for their next scheduled payout",
        payout_period_end_date: payout_period_end_date.to_s,
        user_ids: newly_exhausted
      )
      # Claimed only after the alert is out. A duplicate alert (crash between the two) is a far
      # better failure than the silence that a claim-first order would make permanent — silence is
      # the incident this job exists to prevent.
      newly_exhausted.each do |user_id|
        $redis.set(RedisKey.transient_payout_requeue_exhaustion_reported(user_id, payout_period_end_date),
                   "1", ex: EXHAUSTION_REPORT_DEDUPE_WINDOW.to_i)
      end
    end
    return if user_ids.empty?

    Rails.logger.info("REQUEUE TRANSIENTLY FAILED PAYOUTS: #{payout_period_end_date}, #{user_ids.size} seller(s) (Started)")

    # `retrying: true` skips the payout-cycle gate, which would otherwise reject these sellers:
    # today's payment row (failed or not) and a monthly/quarterly cadence both push
    # #next_payout_cycle_date past this batch's period. Re-issuing is otherwise safe — every
    # payability check still runs, `is_user_payable` refuses while any payment is `processing`,
    # and Payouts.create_payment no-ops once the balances have left `unpaid`.
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
