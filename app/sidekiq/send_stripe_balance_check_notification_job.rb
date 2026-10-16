# frozen_string_literal: true

class SendStripeBalanceCheckNotificationJob
  include Sidekiq::Job
  include CurrencyHelper
  sidekiq_options retry: 1, queue: :default, lock: :until_executed
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 30.minutes

  def perform
    return unless Rails.env.production?
    return if Feature.active?(:disable_stripe_balance_check_notification)

    balance_check = StripeBalanceCheckService.new

    was_needed = $redis.get(RedisKey.stripe_balance_topup_needed) == "true"
    needs_topup = balance_check.topup_needed?
    # The check runs daily, so the one that lands the morning before the cycle's first run is the
    # Monday: it re-sends the verdict with no transition, so the team gets a definite read before
    # any money moves.
    recheck_due = !needs_topup && balance_check.day_before_first_run?
    # Preserve the transition if message construction or enqueueing fails; a retry must still send the all-clear.
    if needs_topup || was_needed || recheck_due
      InternalNotificationWorker.perform_async("payments", "Stripe Balance Check", message_for(balance_check), needs_topup ? "red" : "green")
    end
    $redis.set(RedisKey.stripe_balance_topup_needed, needs_topup)
  end

  private
    def message_for(balance_check)
      first_run = format_run(balance_check.next_payout_run_at)
      last_run = format_run(balance_check.cycle_last_run_at)
      period_end = balance_check.payout_end_date.strftime("%B %-d")
      needs_topup = balance_check.topup_needed?
      pending = formatted_dollar_amount(balance_check.pending_cents)

      lines = [
        needs_topup ? "Action needed, conservatively before the next run: #{first_run}." : "No action needed yet.",
        "Stripe balance as of #{balance_check.balance_read_at.strftime('%H:%M UTC')}: " \
        "#{formatted_dollar_amount(balance_check.current_balance_cents)} " \
        "(#{formatted_dollar_amount(balance_check.available_cents)} available + " \
        "#{pending} pending, which normally settles within a couple of business days).",
        "Seller payouts for balances up to #{period_end} need #{formatted_dollar_amount(balance_check.upcoming_payouts_cents)} " \
        "from Gumroad's Stripe balance in total. The payout jobs run Tuesday to Friday at 10:00 UTC, each paying one group " \
        "of sellers, so the money is drawn in parts between the next run (#{first_run}) and the last run of the cycle " \
        "(#{last_run}).",
        cohort_split(balance_check),
        "Gap counting pending (available + pending against the whole cycle, assuming the #{pending} pending settles " \
        "before it is drawn): #{formatted_dollar_amount([balance_check.topup_amount_cents, 0].max)}. " \
        "Gap if none of the pending settles in time (available alone against the whole cycle): " \
        "#{formatted_dollar_amount(available_only_gap_cents(balance_check))}.",
        "Of Stripe's USD bank payouts created in the last 24 hours, " \
        "#{formatted_dollar_amount(balance_check.swept_to_bank_last_day_cents)} has reached the bank and " \
        "#{formatted_dollar_amount(balance_check.sweeps_in_flight_last_day_cents)} is still in flight. " \
        "A payout draws the Stripe balance down when it is created, not when it settles.",
      ]

      if needs_topup
        lines << "Top up #{formatted_dollar_amount(balance_check.topup_amount_cents)}, the gap counting pending. " \
                 "The check compares the whole cycle with available + pending and does not measure what the next run " \
                 "alone draws, so treat the next run as the deadline to be safe. " \
                 "Nothing tops up automatically: add funds in the Stripe dashboard (Balances > Add to balance) " \
                 "or move the money to the Stripe account from the bank. Payouts the balance cannot cover fail with " \
                 "\"insufficient funds\" and have to be re-run by hand."
      else
        recheck = balance_check.day_before_first_run? ? "This is the Monday re-check before the cycle's first run." : "A re-check goes out on the Monday before the cycle's first run."
        lines << "Nothing to do yet: available + pending covers the whole cycle, assuming the pending settles before it " \
                 "is drawn. This does not check that settled funds alone cover the next run. #{recheck}"
      end

      lines.join("\n")
    end

    def available_only_gap_cents(balance_check)
      [balance_check.upcoming_payouts_cents - balance_check.available_cents, 0].max
    end

    # Cohorts whose run already passed this cycle are sellers that run left unpaid (other payout
    # cadences, holds, failures). They stay in the total, so label them instead of dropping them.
    def cohort_split(balance_check)
      by_weekday = balance_check.per_run_estimate_cents
      ahead = []
      past = []
      StripeBalanceCheckService::PAYOUT_RUN_WDAYS.each do |wday|
        weekday = PayoutRailSchedule::WEEKDAYS[wday]
        cents = by_weekday[weekday].to_i
        next unless cents.positive?

        run_at = balance_check.cycle_last_run_at - (StripeBalanceCheckService::PAYOUT_RUN_WDAYS.last - wday).days
        (run_at < balance_check.next_payout_run_at ? past : ahead) << "#{weekday.to_s.capitalize} #{formatted_dollar_amount(cents)}"
      end

      parts = []
      parts << "runs still ahead: #{ahead.join(', ')}" if ahead.any?
      parts << "already run this cycle and still unpaid (in the total above, not a forecast of another draw): #{past.join(', ')}" if past.any?
      return "By weekday cohort: nothing payable." if parts.empty?

      "By weekday cohort (estimates, which err high): #{parts.join('; ')}."
    rescue ActiveRecord::ActiveRecordError => e
      # Information only: a failed lookup must not stop the verdict from going out.
      ErrorNotifier.notify(e)
      "By weekday cohort: unavailable this time (the lookup failed and was reported). The total above is unaffected."
    end

    def format_run(run_at)
      "#{run_at.strftime('%A, %B %-d')} at #{run_at.strftime('%H:%M')} UTC (#{run_at.in_time_zone('America/New_York').strftime('%-l:%M %p ET')})"
    end
end
