# frozen_string_literal: true

# Relabels the Gumroad-held seller balances that buyer-currency presentment charges stamped with
# the buyer's currency instead of USD (gumroad-private#1471), so that the sellers' payouts stop
# hard-failing.
#
# ## What went wrong
#
# `BalanceTransaction::Amount.create_holding_amount_for_seller` picked the balance's holding
# currency from `flow_of_funds.settled_amount`, which on a buyer-presentment charge is the currency
# the *buyer* was charged in (EUR). For funds Gumroad holds itself the money physically arrives in
# Gumroad's own USD platform account no matter what the buyer paid in, so those balances were
# labelled with a currency Gumroad does not hold. The forward fix is #6505; this service repairs the
# rows written before it.
#
# The mislabelling blocks money. `StripePayoutProcessor.prepare_payment_and_set_amount` refuses to
# sum a Gumroad-held balance whose `holding_currency` is not USD, and `is_balance_payable` returns
# true for *every* Gumroad-held balance regardless of currency — so a mislabelled row is always
# pulled into the payout it then fails. One bad row therefore fails the seller's whole payment,
# including their correctly-labelled USD balances.
#
# ## Why no money is at risk, and where the corrected values come from
#
# Only the *label* and the informational `gross_cents` were ever wrong. Read the broken branch:
#
#     new(currency: flow_of_funds.settled_amount.currency,   # EUR  <- wrong
#         gross_cents: flow_of_funds.settled_amount.cents,   #      <- wrong
#         net_cents: issued_net_cents)                       # USD  <- already correct
#
# `net_cents` was already the canonical USD figure, and `net_cents` is the only field that
# accumulates into `Balance#holding_amount_cents`. So every held *amount* in the ledger is already
# right; nothing is over- or under-credited, and this repair moves no value.
#
# That also means the corrected values do not have to be re-derived from anywhere — they are already
# on the row. At all three seller call sites `create_issued_amount_for_seller` and
# `create_holding_amount_for_seller` are handed identical arguments, and the fixed method's `else`
# branch is field-for-field the same expression as the issued-amount method:
#
#     issued_gross_amount = canonical_issued_amount || flow_of_funds.issued_amount
#     new(currency: issued_gross_amount.currency, gross_cents: issued_gross_amount.cents,
#         net_cents: issued_net_cents)
#
# So what the fix *would* have written is exactly this row's own `issued_amount_*` fields. This
# service copies them across rather than recomputing them, which is why it needs no calls to the
# charge processor: the answer is already stored, and it is the same answer the deployed fix now
# produces for new charges. `assert_amounts_unchanged!` below re-derives the balance total from
# those fields and refuses to proceed if it would move by even one cent.
#
# ## Usage, and the run order that matters
#
# Dry run by default. Balance ids must be passed explicitly — deliberately no "find everything that
# looks wrong" mode, because the affected set is enumerated and reviewed on the tracking issue first.
#
#   Onetime::RestampGumroadHeldPresentmentBalances.new(balance_ids: [...]).process
#   Onetime::RestampGumroadHeldPresentmentBalances.new(balance_ids: [...], dry_run: false).process
#
# **Deploy the forward fix (#6505) before running this.** Ramping `buyer_currency_charging` to 0%
# stopped new *charges* from mislabelling, but it did not fix the code: until #6505 ships, the refund
# path and the dispute-win path still reach the broken branch with a canonical issued amount present,
# so a refund or chargeback booked today against a purchase charged while the lane was live mints a
# fresh mislabelled row. That is not hypothetical — the affected set already contains one such row, a
# chargeback leg booked about 100 minutes after the ramp-down.
#
# So the set is only frozen once #6505 is live, and even then chargebacks on those purchases can
# arrive for weeks, past the late edge of REGRESSION_WINDOW below. This service stays safe in both
# cases — a straggler inside the window is restamped correctly, and one outside it causes the whole
# balance to be refused rather than quietly relabelled — but two operational consequences follow:
# running this before #6505 deploys can leave a repaired seller re-broken by a later refund leg, and
# a clean run is not grounds for calling the incident closed. Re-enumerate before declaring it done.
#
class Onetime::RestampGumroadHeldPresentmentBalances
  # The window in which a mislabelled row could have been written, measured from the affected rows
  # themselves rather than assumed from the ramp timeline: the earliest is 2026-07-23 21:07:18 UTC
  # (buyer-currency charging had reached 100% of sellers) and the latest 2026-07-28 15:18:05 UTC,
  # which is after the 13:37 ramp-down because a dispute leg can still be booked against a purchase
  # that was charged while the lane was live. A day of padding either side absorbs a straggler of
  # that kind without widening this to "any transaction at all".
  #
  # A transaction outside the window did not come from this regression, so this service refuses to
  # touch it. If the enumeration hands us one, that is a signal to investigate rather than relabel.
  REGRESSION_WINDOW = Time.utc(2026, 7, 22, 0, 0)..Time.utc(2026, 7, 29, 23, 59, 59)

  attr_reader :stats, :corrected, :skipped

  def initialize(balance_ids:, dry_run: true, logger: Rails.logger)
    @balance_ids = balance_ids
    @dry_run = dry_run
    @logger = logger
    @stats = Hash.new(0)
    @corrected = []
    @skipped = []
  end

  def process
    log "Starting #{self.class.name} (#{@dry_run ? 'DRY RUN' : 'LIVE'}) for #{@balance_ids.size} balances"

    @balance_ids.each do |balance_id|
      ReplicaLagWatcher.watch unless @dry_run
      process_one(balance_id)
    end

    print_summary
    { stats: @stats, corrected: @corrected, skipped: @skipped }
  end

  private
    def process_one(balance_id)
      @stats[:scanned] += 1

      balance = Balance.find_by(id: balance_id)
      reason = check_eligibility(balance)
      if reason != :eligible
        skip(balance_id, reason)
        return
      end

      if @dry_run
        # Run the same assertion the live path runs, so a dry run cannot report a balance as
        # correctable that the live run would refuse. The dry run is the artifact the set gets
        # reviewed from, so it has to predict the live outcome rather than approximate it.
        begin
          assert_amounts_unchanged!(balance, balance.balance_transactions.to_a)
        rescue => e
          @stats[:would_refuse] += 1
          @skipped << { balance_id:, reason: :would_refuse, error: e.message }
          log "WOULD REFUSE balance #{balance_id}: #{e.message}"
          return
        end

        @stats[:corrected] += 1
        @corrected << correction_summary(balance)
        return
      end

      ApplicationRecord.transaction do
        # Re-read under lock: the enumeration on the issue was taken earlier, and a payout run
        # could have picked this balance up in the meantime.
        balance = Balance.lock.find(balance_id)
        reason = check_eligibility(balance)
        if reason != :eligible
          skip(balance_id, reason)
          raise ActiveRecord::Rollback
        end

        transactions = balance.balance_transactions.to_a
        assert_amounts_unchanged!(balance, transactions)

        transactions.each do |bt|
          # Log the wrong values before overwriting them. `balance_transactions` has no `deleted_at`
          # column, so the usual correction flow (soft-delete the row, write a corrected copy) is
          # not available and there is no soft-deleted original to fall back on — this log line,
          # plus the tracking issue, is the audit trail.
          log "restamping BT #{bt.id} (balance #{balance.id}, purchase #{bt.purchase_id}): " \
              "holding #{bt.holding_amount_currency} gross=#{bt.holding_amount_gross_cents} " \
              "net=#{bt.holding_amount_net_cents} -> #{bt.issued_amount_currency} " \
              "gross=#{bt.issued_amount_gross_cents} net=#{bt.issued_amount_net_cents}"

          # `update_columns` skips the Immutable guard deliberately: these holding fields were wrong
          # from the moment they were written, and the values replacing them come from the same row.
          bt.update_columns(
            holding_amount_currency: bt.issued_amount_currency,
            holding_amount_gross_cents: bt.issued_amount_gross_cents,
            holding_amount_net_cents: bt.issued_amount_net_cents,
            updated_at: Time.current,
          )
        end

        # Only the label changes on the balance itself. `holding_amount_cents` is re-derived and
        # asserted equal above, so it is written back to the same value it already held.
        balance.holding_currency = Currency::USD
        balance.holding_amount_cents = transactions.sum(&:issued_amount_net_cents)
        balance.save!

        @stats[:corrected] += 1
        @corrected << correction_summary(balance)
      end
    rescue => e
      @stats[:error] += 1
      @skipped << { balance_id:, reason: :error, error: "#{e.class}: #{e.message}" }
      log "ERROR on balance #{balance_id}: #{e.class}: #{e.message}"
    end

    # Guards the one property that makes this repair safe to run against the live ledger: relabelling
    # must not move a single cent. If re-deriving the held total from the rows' own issued amounts
    # disagrees with what the balance already holds, then the assumption this service rests on —
    # that `holding_amount_net_cents` was always the canonical USD figure — does not hold for this
    # balance, and it must be looked at by hand instead of relabelled.
    def assert_amounts_unchanged!(balance, transactions)
      rederived = transactions.sum(&:issued_amount_net_cents)
      return if rederived == balance.holding_amount_cents

      raise "Balance #{balance.id}: re-derived holding amount #{rederived} != stored " \
            "#{balance.holding_amount_cents} — refusing to relabel, this is not a pure label fix"
    end

    def check_eligibility(balance)
      return :not_found if balance.nil?

      merchant_account = balance.merchant_account
      return :no_merchant_account if merchant_account.nil?
      # The bug is specific to funds Gumroad holds itself. A seller's own connected account really
      # is settling in its own currency, so a non-USD label there is correct and must be left alone.
      return :not_gumroad_held unless merchant_account.holder_of_funds == HolderOfFunds::GUMROAD
      return :account_not_usd unless usd?(merchant_account.currency)

      # Already-correct balances land here, so re-running after a partial failure is safe: fixed
      # rows are skipped rather than touched twice.
      return :already_usd if usd?(balance.holding_currency)
      # Amounts are only changeable while a balance is unpaid. Anything else means a payout has
      # picked this up since the set was enumerated — investigate rather than touch.
      return :not_unpaid unless balance.unpaid?

      transactions = balance.balance_transactions.to_a
      return :no_balance_transactions if transactions.empty?

      transactions.each do |bt|
        # The issued side is what the corrected holding fields are copied from, so it has to be the
        # canonical USD amount. If it is not, this row was not written by the branch this repairs.
        return :bt_issued_not_usd unless usd?(bt.issued_amount_currency)
        # The corrected holding net must equal what the row already holds, per row and not just in
        # aggregate. Every row written by the broken branch satisfies this by construction (it passed
        # `issued_net_cents` straight through as `net_cents`), so a row that does not was written by
        # something else and its amounts — not merely its label — would change if we copied. Refuse.
        return :bt_net_mismatch unless bt.holding_amount_net_cents == bt.issued_amount_net_cents
        # `find_or_create_balance` keys a balance on its holding currency, so every transaction on a
        # mislabelled balance should share its label. A row that does not means something other than
        # this regression is involved.
        return :bt_currency_disagrees_with_balance unless bt.holding_amount_currency.to_s.downcase == balance.holding_currency.to_s.downcase
        return :bt_outside_regression_window unless REGRESSION_WINDOW.cover?(bt.created_at)
        return :bt_wrong_merchant_account unless bt.merchant_account_id == balance.merchant_account_id
      end

      :eligible
    end

    def usd?(currency)
      currency.to_s.downcase == Currency::USD
    end

    def skip(balance_id, reason)
      @stats[reason] += 1
      @skipped << { balance_id:, reason: }
    end

    def correction_summary(balance)
      transactions = balance.balance_transactions.to_a

      {
        balance_id: balance.id,
        user_id: balance.user_id,
        date: balance.date,
        from_holding_currency: balance.holding_currency,
        to_holding_currency: Currency::USD,
        holding_amount_cents: balance.holding_amount_cents,
        rederived_holding_amount_cents: transactions.sum(&:issued_amount_net_cents),
        balance_transaction_ids: transactions.map(&:id),
      }
    end

    def print_summary
      log "=" * 80
      log "#{self.class.name}: #{@dry_run ? 'DRY RUN' : 'LIVE'}"
      log "=" * 80
      @stats.sort_by { |k, _| k.to_s }.each { |k, v| log "  #{k}: #{v}" }
      log "  sellers_affected: #{@corrected.map { |c| c[:user_id] }.uniq.size}"
      log "  unblocked_cents: #{@corrected.sum { |c| c[:holding_amount_cents] }}"
      @skipped.each { |s| log "  skipped: #{s.inspect}" }
    end

    def log(msg)
      @logger.info("[gumroad-held presentment restamp] #{msg}")
    end
end
