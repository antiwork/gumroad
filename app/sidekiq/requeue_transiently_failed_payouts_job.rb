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
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 1.hour

  # Repeated transient failures stop retrying this currency/account group until its next period.
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

    counts = self.class.failure_counts(payout_period_end_date)
    return if counts.empty?

    eligible, exhausted = counts.keys.partition do |user_id, account_id, currency|
      self.class.retryable_group?(counts, user_id, account_id, currency)
    end
    user_ids = eligible.map(&:first).uniq
    exhausted_user_ids = exhausted.map(&:first).uniq

    # Report each exhausted seller once per payout period. Counting cannot dedupe this: once a
    # seller is over the cap the job stops requeueing them, so their failure count stops growing and
    # any count-based condition stays true on every later run of the same period.
    newly_exhausted = exhausted_user_ids.reject do |user_id|
      $redis.exists?(RedisKey.transient_payout_requeue_exhaustion_reported(user_id, payout_period_end_date))
    end
    if newly_exhausted.present?
      ErrorNotifier.notify(
        "Payouts: #{newly_exhausted.size} seller(s) hit #{MAX_REQUEUE_ATTEMPTS} transient payout failures for #{payout_period_end_date}; exhausted currency/account groups will wait for their next scheduled payout",
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

  def self.failure_counts(date, user_id: nil)
    failures = Payment.failed.reorder(nil).processed_by(PayoutProcessorType::STRIPE)
      .where(failure_reason: Payment::FailureReason::REQUEUEABLE_REASONS, payout_period_end_date: date)
    failures = failures.where(user_id:) if user_id

    failures.includes(:user, balances: :merchant_account).each_with_object(Hash.new(0)) do |payment, counts|
      groups = if payment.stripe_connect_account_id.present? && payment.currency.present?
        [[payment.stripe_connect_account_id, payment.currency]]
      elsif payment.balances.present?
        # Older preparation failures may predate both fields, but retain the claimed balances.
        StripePayoutProcessor.payout_groups(payment.user, payment.balances).map do |account, currency, balances|
          [group_account_id(account, balances), currency]
        end
      else
        [[payment.stripe_connect_account_id.presence, payment.currency.presence]]
      end
      groups.uniq.each { |account_id, currency| counts[[payment.user_id, account_id, currency]] += 1 }
    end
  end

  def self.group_account_id(merchant_account, balances)
    # A replaced account's balances remain a separate group even when preparation rejects them.
    stripe_balance = balances.find { |balance| balance.merchant_account.holder_of_funds == HolderOfFunds::STRIPE }
    (stripe_balance&.merchant_account || merchant_account)&.charge_processor_merchant_id
  end

  def self.retryable_group?(counts, user_id, account_id, currency)
    # Unidentifiable legacy attempts still consume the single-currency seller's allowance.
    keys = [[account_id, currency], [nil, currency], [account_id, nil], [nil, nil]].uniq
    attempts = keys.sum { |account, group_currency| counts.fetch([user_id, account, group_currency], 0) }
    attempts.between?(1, MAX_REQUEUE_ATTEMPTS)
  end
end
