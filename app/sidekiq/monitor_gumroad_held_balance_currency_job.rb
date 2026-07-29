# frozen_string_literal: true

# Watches for the one signal that says the Gumroad-held holding-currency fix is
# holding: a balance whose funds Gumroad holds but whose holding_currency is
# anything other than USD.
#
# Why this exists rather than trusting the code fix alone. Both payout processors
# compare holding_currency to the literal string "usd" in Ruby, and they fail in
# different, asymmetric ways when it does not match:
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
# Three details of the check are deliberate and easy to get wrong:
#
#   1. The comparison is BINARY. The balances table is utf8mb4_unicode_ci, a
#      case-insensitive PAD SPACE collation, so a plain SQL `holding_currency !=
#      "usd"` treats "USD", "Usd" and "usd " as equal to "usd" and skips them --
#      while the processors, comparing in Ruby, treat all three as broken and fail
#      the payout. A monitor that exists because of a silent failure mode must not
#      have a silent blind spot of its own. CAST(... AS BINARY) rather than the
#      shorter `BINARY expr` prefix, which MySQL 8 reports as deprecated and slated
#      for removal.
#   2. NULL is included explicitly. `NULL != "usd"` is NULL in SQL, so a NULL row
#      would be filtered out, yet `nil == "usd"` is false in Ruby and breaks
#      payouts the same way. The model validates presence, but the rows that
#      prompted this monitor ("usdd" and a trailing-newline "usd", from 2023 data
#      entry) are proof that writes bypassing normal creation paths do happen.
#   3. Gumroad-held is decided by MerchantAccount#holder_of_funds, not by
#      `merchant_accounts.user_id IS NULL`. Those two are not the same set: the
#      PayPal and Braintree charge processors report HolderOfFunds::GUMROAD for
#      every merchant account including a seller's own, so scoping on a nil
#      user_id would have missed mislabelled balances that still break payouts.
#      Only the Stripe implementation distinguishes by owner, and there a nil
#      user_id is exactly what makes an account Gumroad-held (a Stripe Connect
#      account always has a user and reports CREATOR). So the SQL below narrows
#      to "platform-owned OR not Stripe", which is an exact superset of
#      Gumroad-held, and holder_of_funds is then confirmed per row in Ruby -- the
#      same call the payout processors make, so the monitor cannot drift from them
#      if that logic changes. Without the SQL narrowing this would load every
#      seller's foreign-currency balance: measured against production, 418 rows a
#      day and rising, against 0 that are actually Gumroad-held.
class MonitorGumroadHeldBalanceCurrencyJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed, on_conflict: :replace

  # Rows created before this are the known historical cohort, already enumerated and
  # handled by the one-off backfill. Alerting on them every run would be pure noise;
  # what matters is whether anything NEW appears. Parsed with an explicit UTC offset
  # so the boundary does not move with the application time zone.
  BASELINE_CUTOFF = Time.zone.parse("2026-07-29T00:00:00Z")

  # Enough seller ids to act on without turning the alert into a wall of text. If a
  # run ever exceeds this, the count in the alert still reports the true total.
  SAMPLE_LIMIT = 25

  # A ceiling on rows loaded into memory, so a regression that mislabels balances at
  # scale produces an alert rather than a job that dies trying to describe it. The
  # count is queried separately, so the alert still reports the true total.
  MAX_ROWS_LOADED = 500

  def perform
    scope = Balance
      .where(state: "unpaid")
      .where("balances.created_at >= ?", BASELINE_CUTOFF)
      .where("balances.holding_currency IS NULL OR CAST(balances.holding_currency AS BINARY) <> ?", Currency::USD)
      .joins(:merchant_account)
      .where(
        "merchant_accounts.user_id IS NULL OR merchant_accounts.charge_processor_id <> ?",
        StripeChargeProcessor.charge_processor_id
      )

    candidates = scope.includes(:merchant_account).order(id: :desc).limit(MAX_ROWS_LOADED).to_a

    # holder_of_funds routes through the charge processor and can raise for a row whose
    # processor no longer resolves. A monitor that raises stops monitoring, so treat an
    # unanswerable row as worth reporting rather than letting it abort the run.
    offending = candidates.select do |balance|
      balance.merchant_account&.holder_of_funds == HolderOfFunds::GUMROAD
    rescue StandardError
      true
    end
    return if offending.empty?

    # A stable message keeps every run of this alert in one Sentry issue instead of
    # opening a new one each day; everything that varies goes in the context.
    ErrorNotifier.notify(
      "Gumroad-held balances have a holding_currency other than USD, which blocks payouts",
      balance_count: offending.size,
      seller_count: offending.map(&:user_id).uniq.size,
      currencies: offending.map(&:holding_currency).uniq,
      created_since: BASELINE_CUTOFF.iso8601,
      truncated: candidates.size == MAX_ROWS_LOADED,
      sample: offending.first(SAMPLE_LIMIT).map do |balance|
        {
          balance_id: balance.id,
          seller_id: balance.user_id,
          holding_currency: balance.holding_currency,
          amount_cents: balance.amount_cents,
          date: balance.date.to_s,
        }
      end
    )
  end
end
