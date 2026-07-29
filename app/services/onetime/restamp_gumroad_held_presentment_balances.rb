# frozen_string_literal: true

# Relabels the Gumroad-held seller balances that buyer-currency presentment charges stamped with
# the buyer's currency instead of USD (gumroad-private#1471), so that the sellers' payouts stop
# being blocked.
#
# ## What went wrong
#
# `BalanceTransaction::Amount.create_holding_amount_for_seller` picked the balance's holding
# currency from `flow_of_funds.settled_amount`, which on a buyer-presentment charge is the currency
# the *buyer* was charged in (EUR).
#
# For funds Gumroad holds, `holding_*` is Gumroad's canonical record of what it owes the seller — a
# liability, always denominated in USD, because USD is the currency every Gumroad-held payout is
# computed and wired in. It is deliberately not a record of which currency Stripe is physically
# sitting on. Stripe's platform account genuinely does hold foreign-currency balances (an audit of
# this cohort found all 50 sampled charges settled in EUR and stayed there), but that is an
# account-level treasury position spanning every seller, and nothing about paying one seller
# follows from it. So the settled currency was the wrong source even where it was factually what
# Stripe settled. The forward fix is #6505; this service repairs the rows written before it.
#
# The mislabelling blocks money, and it does so differently on each payout processor:
#
#   - `StripePayoutProcessor.prepare_payment_and_set_amount` refuses to sum a Gumroad-held balance
#     whose `holding_currency` is not USD, and its `is_balance_payable` returns true for *every*
#     Gumroad-held balance regardless of currency — so a mislabelled row is always pulled into the
#     payout it then fails. One bad row fails the seller's whole payment, including their
#     correctly-labelled USD balances. This is loud: it leaves a `failed` payment with
#     `currency_mismatch`, which is how the incident was noticed at all.
#   - `PaypalPayoutProcessor.is_balance_payable` requires USD, so it drops the bad row *before* a
#     payment object exists. No failed payment, no failure reason, nothing in Sentry — the seller
#     is quietly short-paid and the only trace is a balance that stays unpaid while newer ones get
#     paid. This is the majority of the affected sellers.
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
# service copies all three across rather than recomputing them, which is why it needs no calls to
# the charge processor: the answer is already stored, and it is the same answer the deployed fix now
# produces for new charges. Copying the gross matters as much as the currency — relabelling the
# currency alone would leave an EUR figure in `holding_amount_gross_cents` under a USD label, which
# is a worse row than the one we started with. `assert_amounts_unchanged!` below re-derives the
# balance total from those fields and refuses to proceed if it would move by even one cent.
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
# The service enforces that order rather than trusting it: `REGRESSION_WINDOW` closes at #6505's
# actual production deployment time (see the constant below), so a row written after the fix shipped
# causes its whole balance to be refused rather than quietly relabelled. If the enumeration hands us
# one, the fix is not doing its job and that is the thing to investigate.
#
# Two further operational consequences follow, and neither is fixable from inside this service:
# running it before #6505 deploys can leave a repaired seller re-broken by a later refund leg, and a
# clean run is not grounds for calling the incident closed, because chargebacks on these purchases
# can keep arriving for weeks. Re-enumerate before declaring it done.
#
class Onetime::RestampGumroadHeldPresentmentBalances
  # The earliest a mislabelled row could exist, measured from the affected rows themselves rather
  # than assumed from the ramp timeline: the earliest is 2026-07-23 21:07:18 UTC, when
  # buyer-currency charging had reached 100% of sellers. A day of padding absorbs a straggler
  # without widening this to "any transaction at all".
  REGRESSION_WINDOW_START = Time.utc(2026, 7, 22, 0, 0)

  # The late edge is #6505's actual production deployment time, which is the moment the code stopped
  # being able to write one of these rows. It has to be passed in rather than hardcoded, because at
  # the time this service was written #6505 had not deployed and any constant here would have been a
  # guess — and a guessed cutoff that is too late is exactly the failure this bound exists to catch.
  #
  # Get it from the release that contains the fix, not from when the pull request merged (merging is
  # not deploying):
  #
  #   gh api repos/antiwork/gumroad/releases --jq '.[] | select(.body | contains("#6505")) | .published_at'
  #
  # A transaction written after that instant did not come from this regression — the deployed code
  # cannot produce one — so its presence means either the cutoff is wrong or the fix is not working.
  # Either way it is a signal to investigate, and this service refuses the balance rather than
  # relabelling it.
  def self.regression_window(fix_deployed_at)
    REGRESSION_WINDOW_START..fix_deployed_at
  end

  attr_reader :stats, :corrected, :skipped

  def initialize(balance_ids:, fix_deployed_at:, dry_run: true, logger: Rails.logger)
    raise ArgumentError, "fix_deployed_at is required: pass #6505's production deployment time" if fix_deployed_at.blank?
    raise ArgumentError, "fix_deployed_at #{fix_deployed_at} precedes the regression window start" if fix_deployed_at <= REGRESSION_WINDOW_START

    @balance_ids = balance_ids
    @regression_window = self.class.regression_window(fix_deployed_at)
    @dry_run = dry_run
    @logger = logger
    @stats = Hash.new(0)
    @corrected = []
    @skipped = []
  end

  def process
    log "Starting #{self.class.name} (#{@dry_run ? 'DRY RUN' : 'LIVE'}) for #{@balance_ids.size} balances"
    log "Regression window: #{@regression_window.first} .. #{@regression_window.last} (#6505 deployment)"

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
        return :bt_outside_regression_window unless @regression_window.cover?(bt.created_at)
        return :bt_wrong_merchant_account unless bt.merchant_account_id == balance.merchant_account_id
        # Positive proof that this row came from the buyer-presentment path, rather than inference
        # from "non-USD label on a Gumroad-held account".
        #
        # The broken branch only fired when `canonical_issued_amount` was present, and that value
        # comes from `Purchase#presentment_canonical_issued_amount`, which returns nil unless the
        # purchase has a `PurchasePresentment`. So a row from this regression always traces back to a
        # purchase with presentment records — no quote required, which is what makes this the right
        # check rather than looking for a `stripe_fx_quote_id` (the majority of the affected rows are
        # from forced-currency local methods that take no quote at all).
        #
        # A non-USD Gumroad-held row *without* presentment records was mislabelled by something else
        # and is not this service's business.
        reason = presentment_backed?(bt)
        return reason unless reason == :ok
      end

      :eligible
    end

    # Whether this balance transaction traces back to purchases with presentment records, which is
    # the signature of the branch this service repairs.
    #
    # Refund and dispute legs carry no `purchase_id` of their own — they hang off the refund or
    # dispute — so the purchases are resolved through whichever association is present. Anything with
    # no reachable purchase at all (a credit leg, say) cannot be shown to come from this regression
    # and is refused.
    #
    # A dispute needs one more step than a refund: a dispute raised against a combined-cart charge
    # is recorded on the Charge itself (`disputes.charge_id` set, `disputes.purchase_id` empty), so
    # reading only `dispute.purchase` refuses those legs as having no related purchase — and the
    # affected set contains exactly that shape, a chargeback leg against a charge-level dispute.
    # `Dispute#purchases` resolves both shapes: the charge's purchases when the dispute is
    # charge-level, the directly-attached purchase otherwise. Every reachable purchase must carry
    # presentment records; a charge whose purchases disagree on that was not written by this
    # regression (presentment rows are created for all of a presentment charge's purchases or none),
    # so it is refused for hand review rather than relabelled.
    def presentment_backed?(balance_transaction)
      purchases =
        if balance_transaction.purchase
          [balance_transaction.purchase]
        elsif balance_transaction.refund
          [balance_transaction.refund.purchase]
        elsif balance_transaction.dispute
          balance_transaction.dispute.purchases
        else
          []
        end.compact

      return :bt_no_related_purchase if purchases.empty?
      return :bt_purchase_not_presentment unless purchases.all? { |purchase| purchase.purchase_presentment.present? }

      :ok
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
