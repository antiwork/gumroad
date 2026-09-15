# frozen_string_literal: true

# Determines whether Gumroad's Stripe platform balance is large enough to
# fund the upcoming seller payouts. Stripe pays out Gumroad's balance to
# Gumroad's bank automatically, and seller payouts (platform -> connected
# account transfers) draw from the same balance, so the balance can be
# starved before a payout cycle runs. This service powers a proactive alert
# so the balance can be topped up before any seller payout fails.
class StripeBalanceCheckService
  # Scheduled payout jobs fire at UTC 10:00 Tuesday-Friday (config/sidekiq_schedule.yml).
  PAYOUT_RUN_HOUR_UTC = 10
  PAYOUT_RUN_WDAYS = [2, 3, 4, 5].freeze

  def initialize(now: Time.current)
    @now = now.utc
    @payout_end_date = User::PayoutSchedule.next_scheduled_payout_end_date
    @upcoming_payouts_cents = PayoutEstimates.estimate_gumroad_held_stripe_cents(@payout_end_date)

    balance = Stripe::Balance.retrieve
    @available_cents = usd_cents(balance.available)
    # Pending sales settle within a couple of business days -- inside the weekly payout window --
    # so they fund the upcoming payouts. Available-only over-reports the top-up and fires false alarms.
    @pending_cents = [usd_cents(balance.pending), 0].max
  end

  attr_reader :upcoming_payouts_cents, :available_cents, :pending_cents, :payout_end_date

  def current_balance_cents
    available_cents + pending_cents
  end

  def topup_amount_cents
    @topup_amount_cents ||= upcoming_payouts_cents - current_balance_cents
  end

  def topup_needed?
    topup_amount_cents > 0
  end

  # The next scheduled payout run: the first draw on the balance.
  def next_payout_run_at
    @next_payout_run_at ||= begin
      run_at = @now.beginning_of_day + PAYOUT_RUN_HOUR_UTC.hours
      run_at += 1.day if run_at <= @now
      run_at += 1.day until PAYOUT_RUN_WDAYS.include?(run_at.wday)
      run_at
    end
  end

  # The cycle's last run (Friday). The estimate covers every weekday cohort, so this is the point
  # by which the whole amount has been drawn.
  def cycle_last_run_at
    @cycle_last_run_at ||= begin
      run_at = next_payout_run_at
      run_at += 1.day until run_at.wday == PAYOUT_RUN_WDAYS.last
      run_at
    end
  end

  # Stripe's automatic sweeps to Gumroad's bank are what drain the balance; the last day's paid total
  # tells the reader where the money went.
  def swept_to_bank_last_day_cents
    @swept_to_bank_last_day_cents ||= Stripe::Payout.list(
      created: { gte: (@now - 1.day).to_i },
      limit: 100
    ).auto_paging_each.sum do |payout|
      payout.currency == Currency::USD && payout.status == "paid" ? payout.amount : 0
    end
  end

  private
    def usd_cents(balances)
      balances.sum { |entry| entry["currency"] == Currency::USD ? entry["amount"] : 0 }
    end
end
