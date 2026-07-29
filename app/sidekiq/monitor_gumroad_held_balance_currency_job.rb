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
#      day and rising, against 0 that are actually Gumroad-held. The join is a LEFT
#      join because a balance with no merchant account at all breaks payouts too --
#      is_balance_payable dereferences it -- and an inner join would have hidden
#      exactly that row.
class MonitorGumroadHeldBalanceCurrencyJob
  include Sidekiq::Job
  # lock alone, without on_conflict: :replace -- CONTRIBUTING.md warns that :replace has to
  # scroll the Scheduled Set to find the job it is replacing. This job takes no arguments, so
  # until_executed already makes a duplicate enqueue a no-op, which is all that is wanted.
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  # Rows created before this are the known historical cohort, already enumerated and
  # handled by the one-off backfill. Alerting on them every run would be pure noise;
  # what matters is whether anything NEW appears. Parsed with an explicit UTC offset
  # so the boundary does not move with the application time zone.
  BASELINE_CUTOFF = Time.zone.parse("2026-07-29T00:00:00Z")

  # Enough balances to act on without turning the alert into a wall of text.
  SAMPLE_LIMIT = 25

  # A ceiling on rows loaded into memory, so a regression that mislabels balances at
  # scale produces an alert rather than a job that dies trying to describe it. The
  # alert reports whether it hit this ceiling, since the loaded rows are then only
  # part of the picture.
  MAX_ROWS_LOADED = 500

  def perform
    candidates = Balance
      .where(state: "unpaid")
      .where("balances.created_at >= ?", BASELINE_CUTOFF)
      .where("balances.holding_currency IS NULL OR CAST(balances.holding_currency AS BINARY) <> ?", Currency::USD)
      .left_joins(:merchant_account)
      .where(
        "merchant_accounts.id IS NULL OR merchant_accounts.user_id IS NULL " \
        "OR merchant_accounts.charge_processor_id <> ?",
        StripeChargeProcessor.charge_processor_id
      )
      .includes(:merchant_account)
      .order(id: :desc)
      .limit(MAX_ROWS_LOADED)
      .to_a

    offending, unresolved = partition_by_holder_of_funds(candidates)
    return if offending.empty? && unresolved.empty?

    # A stable message keeps every run of this alert in one Sentry issue instead of
    # opening a new one each day; everything that varies goes in the context.
    ErrorNotifier.notify(
      "Gumroad-held balances have a holding_currency other than USD, which blocks payouts",
      balance_count: offending.size,
      seller_count: offending.map(&:user_id).uniq.size,
      currencies: offending.map(&:holding_currency).uniq,
      created_since: BASELINE_CUTOFF.iso8601,
      # True when the query hit MAX_ROWS_LOADED, in which case the counts above describe
      # the rows that were read rather than everything that matches.
      hit_row_limit: candidates.size == MAX_ROWS_LOADED,
      sample: offending.first(SAMPLE_LIMIT).map { describe(_1) },
      # Rows whose holder_of_funds could not be answered at all. Reported separately so a
      # resolution failure never masquerades as a mislabelled balance, and kept out of the
      # counts above so it cannot inflate them.
      unresolved_sample: unresolved.first(SAMPLE_LIMIT).map { describe(_1) }
    )
  end

  private
    # holder_of_funds resolves through the charge processor. It falls back to GUMROAD for a
    # processor it no longer recognises, so today it does not raise -- but a monitor that
    # dies on one row stops watching every other row, so a row it cannot answer for is
    # reported in its own bucket rather than allowed to abort the run or to be counted as a
    # mislabelled balance.
    def partition_by_holder_of_funds(candidates)
      offending = []
      unresolved = []

      candidates.each do |balance|
        merchant_account = balance.merchant_account

        # No merchant account at all: nothing to resolve, and not something to judge as
        # correctly labelled either. is_balance_payable dereferences it, so the row is a
        # payout problem regardless of its currency.
        if merchant_account.nil?
          unresolved << balance
          next
        end

        holder = begin
          merchant_account.holder_of_funds
        rescue StandardError
          :unresolved
        end

        case holder
        when HolderOfFunds::GUMROAD then offending << balance
        when :unresolved then unresolved << balance
        end
      end

      [offending, unresolved]
    end

    def describe(balance)
      {
        balance_id: balance.id,
        seller_id: balance.user_id,
        holding_currency: balance.holding_currency,
        amount_cents: balance.amount_cents,
        date: balance.date.to_s,
      }
    end
end
