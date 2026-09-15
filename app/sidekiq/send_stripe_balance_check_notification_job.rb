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
    $redis.set(RedisKey.stripe_balance_topup_needed, balance_check.topup_needed?)

    if balance_check.topup_needed?
      notify(balance_check, "red")
    elsif was_needed
      # Yesterday's alert asked for money; say so when it's no longer needed.
      notify(balance_check, "green")
    end
  end

  private
    def notify(balance_check, color)
      InternalNotificationWorker.perform_async("payments", "Stripe Balance Check", message_for(balance_check), color)
    end

    def message_for(balance_check)
      first_run = format_run(balance_check.next_payout_run_at)
      last_run = format_run(balance_check.cycle_last_run_at)
      period_end = balance_check.payout_end_date.strftime("%B %-d")

      lines = [
        "Seller payouts for balances up to #{period_end} need #{formatted_dollar_amount(balance_check.upcoming_payouts_cents)} " \
        "from Gumroad's Stripe balance in total. The payout jobs run Tuesday to Friday at 10:00 UTC, each paying one group " \
        "of sellers, so the money is drawn in parts between the next run (#{first_run}) and the last run of the cycle " \
        "(#{last_run}). The figure has no per-run split, so treat the full amount as due by the next run to be safe.",
        "Stripe balance: #{formatted_dollar_amount(balance_check.current_balance_cents)} " \
        "(#{formatted_dollar_amount(balance_check.available_cents)} available + " \
        "#{formatted_dollar_amount(balance_check.pending_cents)} pending, which normally settles within a couple of business days).",
        "Stripe paid #{formatted_dollar_amount(balance_check.swept_to_bank_last_day_cents)} out to Gumroad's bank in the last 24 hours; " \
        "those automatic sweeps are what draw the balance down.",
      ]

      if balance_check.topup_needed?
        lines << "A top-up of #{formatted_dollar_amount(balance_check.topup_amount_cents)} is needed, ideally before #{first_run} " \
                 "and no later than #{last_run}. " \
                 "Nothing tops up automatically: add funds in the Stripe dashboard (Balances > Add to balance) " \
                 "or move the money to the Stripe account from the bank. Payouts the balance cannot cover fail with " \
                 "\"insufficient funds\" and have to be re-run by hand."
      else
        lines << "No top-up needed: the balance now covers the cycle. Nothing to do."
      end

      lines.join("\n")
    end

    def format_run(run_at)
      "#{run_at.strftime('%A, %B %-d')} at #{run_at.strftime('%H:%M')} UTC (#{run_at.in_time_zone('America/New_York').strftime('%-l:%M %p ET')})"
    end
end
