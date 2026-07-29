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
#      account always has a user and reports CREATOR). So the SQL below excludes
#      only one shape -- a Stripe account belonging to a seller. One row would be
#      excluded that Ruby still calls Gumroad-held: a Stripe account whose user row
#      was HARD-deleted (holder_of_funds tests the association, the SQL reads the
#      column). Everything the SQL does admit has holder_of_funds confirmed per row
#      in Ruby, the same call the payout processors make, so the monitor cannot
#      drift from them if that logic changes.
#      Without that exclusion this would load every seller's foreign-currency
#      balance: measured against production, 418 rows and rising, against 0 that are
#      actually Gumroad-held. That is not only wasted work -- those rows would eat
#      the MAX_ROWS_LOADED budget below and could push a genuinely mislabelled
#      Gumroad-held balance out of every run's window, which is silence. The join is
#      a LEFT join because a balance with no merchant account at all breaks payouts
#      too -- is_balance_payable dereferences it -- and an inner join would have
#      hidden exactly that row.
#
# Deliberately OUT of scope: a Gumroad-MANAGED Stripe balance (holder_of_funds
# STRIPE) whose holding_currency does not match its merchant account's own
# currency. StripePayoutProcessor.is_balance_payable drops those silently too, but
# they are non-USD by design, so "is it USD?" is the wrong test for them and a
# monitor of that invariant would compare against the account currency instead.
# This job watches the Gumroad-held/USD invariant only.
class MonitorGumroadHeldBalanceCurrencyJob
  include Sidekiq::Job
  # This job takes no arguments, so until_executed already makes a duplicate enqueue a
  # no-op; :replace is not used because it has to scroll the Scheduled Set to find the job
  # it would replace. Queue :default rather than :low because the run only means anything if
  # it lands before the 08:00 payouts, which a backed-up low queue cannot promise.
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  # The historical cohort that prompted this monitor was enumerated and corrected by hand,
  # so alerting on it every run would be pure noise; what matters is whether anything NEW
  # appears. Parsed with an explicit UTC offset so the boundary does not move with the
  # application time zone.
  #
  # Compared against updated_at rather than created_at, because a bad holding_currency does
  # not only arrive when a row is created. Nothing stops the column being rewritten later --
  # the model's immutability check covers only the amount columns, and
  # Onetime::CorrectSelfAffiliateBackfillHoldingCurrency exists precisely because a backfill
  # wrote wrong holding currencies onto rows that already existed. A repair like that going
  # wrong on an older row is the same incident this monitor watches for, and keying off
  # created_at would never see it. updated_at is a strict superset of created_at (it starts
  # equal and only moves forward) and costs no extra noise: an old row that was touched but
  # is correctly labelled still reads "usd" and does not match the currency test below. The
  # one case it cannot see is a raw update_all/update_column that rewrites the currency on a
  # PRE-baseline row without bumping the timestamp; the repair services in this codebase set
  # updated_at explicitly when they use update_columns, so that stays hypothetical.
  BASELINE_CUTOFF = Time.zone.parse("2026-07-29T00:00:00Z")

  # Enough balances to act on without turning the alert into a wall of text.
  SAMPLE_LIMIT = 25

  # A ceiling on rows loaded into memory, so a regression that mislabels balances at
  # scale produces an alert rather than a job that dies trying to describe it. The
  # alert reports whether it hit this ceiling, since the loaded rows are then only
  # part of the picture, and a separate count reports the true total. Rows come
  # oldest-first, so when the ceiling truncates, the balances that have been blocking
  # payouts longest are the ones that survive into the alert.
  MAX_ROWS_LOADED = 500

  # A stable message keeps every run of an alert in one Sentry issue instead of opening a new
  # one each day; everything that varies goes in the context.
  OFFENDING_MESSAGE = "Gumroad-held balances have a holding_currency other than USD, which blocks payouts"

  # Deliberately does not claim the balances are mislabelled -- whether they are is exactly what
  # could not be determined.
  UNRESOLVED_MESSAGE = "Could not determine whether a non-USD balance is Gumroad-held, so the payout currency check did not run on it"

  def perform
    scope = candidate_scope
    candidates = scope.order(id: :asc).limit(MAX_ROWS_LOADED).to_a

    offending, unresolved = partition_by_holder_of_funds(candidates)
    return if offending.empty? && unresolved.empty?

    hit_row_limit = candidates.size >= MAX_ROWS_LOADED
    # How many rows the QUERY matched, asked for only when the ceiling truncated the run:
    # without it "500 balances" reads the same whether the real number is 501 or 50,000, which
    # is the difference between a stray row and an incident. The count runs over the same
    # indexed range as the scan, so it is cheap on the rare day it is asked.
    #
    # Named for the candidate scope, not for either bucket: it spans both, and on a truncated
    # run neither bucket's true total is knowable, since which side of the split a row falls on
    # is decided per row by holder_of_funds in Ruby and the unread rows were never resolved. A
    # bucket-shaped name next to balance_count would read as the confirmed-violation total.
    candidate_row_count = hit_row_limit ? scope.count : candidates.size

    # The two buckets get their own alerts with their own wording, because they call for
    # different responses: a confirmed mislabelled balance is a payout that will break, while
    # an unresolvable row means the monitor itself could not answer the question. Sending both
    # under the currency-violation message would report a monitor failure as a payout incident.
    notify_offending(offending, hit_row_limit:, candidate_row_count:) if offending.any?
    notify_unresolved(unresolved, hit_row_limit:, candidate_row_count:) if unresolved.any?
  end

  private
    def notify_offending(offending, hit_row_limit:, candidate_row_count:)
      ErrorNotifier.notify(
        OFFENDING_MESSAGE,
        balance_count: offending.size,
        seller_count: offending.map(&:user_id).uniq.size,
        currencies: offending.map(&:holding_currency).uniq,
        created_since: BASELINE_CUTOFF.iso8601,
        # True when the query hit MAX_ROWS_LOADED, in which case balance_count is a floor:
        # candidate_row_count rows matched, and the unread remainder splits between this
        # bucket and the unresolved one in a proportion the run never learned.
        hit_row_limit:,
        candidate_row_count:,
        sample: offending.first(SAMPLE_LIMIT).map { describe(_1) }
      )
    end

    def notify_unresolved(unresolved, hit_row_limit:, candidate_row_count:)
      ErrorNotifier.notify(
        UNRESOLVED_MESSAGE,
        unresolved_count: unresolved.size,
        seller_count: unresolved.map { |balance, _reason| balance.user_id }.uniq.size,
        reasons: unresolved.map { |_balance, reason| reason }.uniq,
        created_since: BASELINE_CUTOFF.iso8601,
        hit_row_limit:,
        candidate_row_count:,
        unresolved_sample: unresolved.first(SAMPLE_LIMIT).map { |balance, reason| describe(balance).merge(reason:) }
      )
    end

    def candidate_scope
      Balance
        .where(state: "unpaid")
        .where("balances.updated_at >= ?", BASELINE_CUTOFF)
        .where("balances.holding_currency IS NULL OR CAST(balances.holding_currency AS BINARY) <> ?", Currency::USD)
        .left_joins(:merchant_account)
        # Everything except a Stripe account that belongs to a seller. Written as a NOT
        # around the one excluded shape rather than as a list of included ones, so that
        # an unfamiliar row shape is kept and answered for in Ruby rather than dropped.
        # The CAST and the COALESCE are load-bearing for the same collation and NULL
        # reasons as the currency test above -- see header notes 1 and 2.
        .where.not(
          "merchant_accounts.user_id IS NOT NULL AND " \
          "CAST(COALESCE(merchant_accounts.charge_processor_id, '') AS BINARY) = ?",
          StripeChargeProcessor.charge_processor_id
        )
        # preload, so the merchant accounts arrive in one extra query and the per-row
        # holder_of_funds check below does not issue one query per balance. The left_joins
        # above stays regardless: the exclusion is a string condition naming
        # merchant_accounts, so the join has to be in the query for it to resolve at all.
        .preload(:merchant_account)
    end

    # holder_of_funds resolves through the charge processor. It falls back to GUMROAD for a
    # processor it no longer recognises, so today it does not raise -- but a monitor that
    # dies on one row stops watching every other row, so a row it cannot answer for is
    # reported in its own alert rather than allowed to abort the run or to be counted as a
    # mislabelled balance. The error text travels with the row: if a deploy breaks
    # holder_of_funds, a list of balance ids alone would not say why, and nothing else
    # reaches Sentry because the exception is swallowed here.
    def partition_by_holder_of_funds(candidates)
      offending = []
      unresolved = []

      candidates.each do |balance|
        merchant_account = balance.merchant_account

        # No merchant account at all: nothing to resolve, and not something to judge as
        # correctly labelled either. is_balance_payable dereferences it, so the row is a
        # payout problem regardless of its currency.
        if merchant_account.nil?
          unresolved << [balance, "no merchant account"]
          next
        end

        begin
          holder = merchant_account.holder_of_funds
          offending << balance if holder == HolderOfFunds::GUMROAD
        rescue StandardError => e
          unresolved << [balance, "#{e.class}: #{e.message}"]
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
