# frozen_string_literal: true

# Watches for the one signal that says the Gumroad-held holding-currency fix is
# holding: a balance on a Gumroad-held merchant account whose holding_currency is
# anything other than USD.
#
# Why this exists rather than trusting the code fix alone. Both payout processors
# compare holding_currency to the literal string "usd" and fail in different,
# asymmetric ways when it does not match:
#
#   - StripePayoutProcessor.is_balance_payable admits EVERY Gumroad-held balance
#     regardless of currency, so a mislabelled row is pulled into the payout and
#     then rejected by prepare_payment_and_set_amount, failing the seller's whole
#     payment with CURRENCY_MISMATCH and taking their correctly-labelled USD
#     balances down with it. Loud, but only after the payout run.
#   - PaypalPayoutProcessor.is_balance_payable requires USD, so it drops the row
#     before a payment object exists. The seller is quietly short-paid and nothing
#     is recorded anywhere -- no failure, no Sentry event.
#
# That second failure mode is why a monitor is worth having at all: it is the half
# of the original incident that produced no signal, and the reason affected sellers
# were found by hand rather than by an alert.
#
# The check is deliberately currency-agnostic rather than looking for the specific
# presentment currencies seen so far. Two of the rows this found in production
# carried "usdd" and "usd\n" -- a 2023 data-entry typo with nothing to do with
# buyer-currency presentment, which the exact string comparison rejects just the
# same. A monitor that only looked for known currency codes would have missed them.
class MonitorGumroadHeldBalanceCurrencyJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  # Rows created before this are the known historical cohort, already enumerated and
  # handled by the one-off backfill. Alerting on them every run would be pure noise;
  # what matters is whether anything NEW appears.
  BASELINE_CUTOFF = Time.zone.parse("2026-07-29T00:00:00Z")

  def perform
    offending = Balance
      .where.not(holding_currency: Currency::USD)
      .joins(:merchant_account)
      .where(merchant_accounts: { user_id: nil })
      .where(state: "unpaid")

    fresh = offending.where("balances.created_at >= ?", BASELINE_CUTOFF)
    return if fresh.none?

    # Report the whole affected set, not just a count: the seller ids are what
    # someone has to act on, and the currencies distinguish a presentment
    # regression from a malformed-string one.
    sample = fresh.order(id: :desc).limit(25).map do |balance|
      "balance=#{balance.id} seller=#{balance.user_id} " \
        "holding_currency=#{balance.holding_currency.inspect} " \
        "amount_cents=#{balance.amount_cents} date=#{balance.date}"
    end

    ErrorNotifier.notify(
      "Gumroad-held balances with a non-USD holding_currency created since " \
      "#{BASELINE_CUTOFF.to_date}: #{fresh.count} row(s) across " \
      "#{fresh.distinct.count(:user_id)} seller(s), currencies " \
      "#{fresh.distinct.pluck(:holding_currency).inspect}. These block payouts: " \
      "Stripe fails the seller's whole payment with CURRENCY_MISMATCH, PayPal " \
      "silently drops the row and short-pays. Sample:\n#{sample.join("\n")}"
    )
  end
end
