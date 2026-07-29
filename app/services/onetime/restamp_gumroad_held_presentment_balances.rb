# frozen_string_literal: true

# Relabels the Gumroad-held seller balances that buyer-currency presentment charges stamped with
# the buyer's currency instead of USD (gumroad-private#1471). Gumroad-held holding fields are the
# canonical USD record of what Gumroad owes the seller, and both payout processors reject non-USD
# Gumroad-held balances — Stripe fails the seller's whole payment with `currency_mismatch`, PayPal
# silently drops the row. The forward fix is #6505; this repairs the rows written before it.
#
# Only the label and gross were wrong: `holding_amount_net_cents` (the only field that accumulates
# into the balance) was already the canonical USD figure, and what the fixed code would have
# written is exactly the row's own `issued_amount_*` fields — so the repair copies those across
# and moves no money.
#
# Dry run by default. Explicit ids only — the worklist is enumerated and reviewed on the tracking
# issue, not discovered here:
#
#   Onetime::RestampGumroadHeldPresentmentBalances.new(balance_ids: [...], fix_deployed_at: ...).process
#   Onetime::RestampGumroadHeldPresentmentBalances.new(balance_ids: [...], fix_deployed_at: ..., dry_run: false).process
#
# Run only after #6505 deploys, and re-freeze the worklist at run time: until the fix ships,
# refund and chargeback legs on presentment purchases keep minting fresh mislabelled rows — the
# flag ramp-down alone did not stop this. The regression window below enforces the ordering.
class Onetime::RestampGumroadHeldPresentmentBalances
  # A day before the earliest mislabelled row (2026-07-23 21:07 UTC, when the ramp hit 100%).
  REGRESSION_WINDOW_START = Time.utc(2026, 7, 22, 0, 0)

  # The late edge is #6505's actual production deploy time — from the release that contains it,
  # not the merge. Deployed code cannot write these rows, so a transaction after this instant
  # means the cutoff or the fix is wrong, and the balance is refused rather than relabelled.
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
        # Same assertion the live path runs, so the dry run predicts the live outcome.
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
        # Re-read under lock: a payout run could have picked this balance up since enumeration.
        balance = Balance.lock.find(balance_id)
        reason = check_eligibility(balance)
        if reason != :eligible
          skip(balance_id, reason)
          raise ActiveRecord::Rollback
        end

        transactions = balance.balance_transactions.to_a
        assert_amounts_unchanged!(balance, transactions)

        # Snapshot before the rewrite — this is the only record of the pre-repair state.
        summary = correction_summary(balance, transactions)

        transactions.each do |bt|
          # balance_transactions has no deleted_at, so this log line is the audit trail.
          log "restamping BT #{bt.id} (balance #{balance.id}, purchase #{bt.purchase_id}): " \
              "holding #{bt.holding_amount_currency} gross=#{bt.holding_amount_gross_cents} " \
              "net=#{bt.holding_amount_net_cents} -> #{bt.issued_amount_currency} " \
              "gross=#{bt.issued_amount_gross_cents} net=#{bt.issued_amount_net_cents}"

          # update_columns skips the immutability guard deliberately: these fields were wrong from
          # the moment they were written, and the replacements come from the same row.
          bt.update_columns(
            holding_amount_currency: bt.issued_amount_currency,
            holding_amount_gross_cents: bt.issued_amount_gross_cents,
            holding_amount_net_cents: bt.issued_amount_net_cents,
            updated_at: Time.current,
          )
        end

        # Only the label changes; the total was asserted equal above.
        balance.holding_currency = Currency::USD
        balance.holding_amount_cents = transactions.sum(&:issued_amount_net_cents)
        balance.save!

        @stats[:corrected] += 1
        @corrected << summary
      end
    rescue => e
      @stats[:error] += 1
      @skipped << { balance_id:, reason: :error, error: "#{e.class}: #{e.message}" }
      log "ERROR on balance #{balance_id}: #{e.class}: #{e.message}"
    end

    # Relabelling must not move a cent: if the total re-derived from the rows' issued amounts
    # disagrees with what the balance holds, this is not a pure label fix — refuse.
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
      # Only Gumroad-held funds are affected; a connected account's non-USD label is correct.
      return :not_gumroad_held unless merchant_account.holder_of_funds == HolderOfFunds::GUMROAD
      return :account_not_usd unless usd?(merchant_account.currency)

      # Already-corrected rows are skipped, so re-runs after a partial failure are safe.
      return :already_usd if usd?(balance.holding_currency)
      # Amounts are only changeable while unpaid; anything else means a payout picked it up.
      return :not_unpaid unless balance.unpaid?

      transactions = balance.balance_transactions.to_a
      return :no_balance_transactions if transactions.empty?

      transactions.each do |bt|
        # The issued side is what gets copied, so it must be the canonical USD amount.
        return :bt_issued_not_usd unless usd?(bt.issued_amount_currency)
        # The broken branch passed issued_net_cents straight through as the holding net, so a row
        # where these disagree came from something else and copying would move money.
        return :bt_net_mismatch unless bt.holding_amount_net_cents == bt.issued_amount_net_cents
        # Balances are keyed on holding currency, so every row should share the balance's label.
        return :bt_currency_disagrees_with_balance unless bt.holding_amount_currency.to_s.downcase == balance.holding_currency.to_s.downcase
        return :bt_outside_regression_window unless @regression_window.cover?(bt.created_at)
        return :bt_wrong_merchant_account unless bt.merchant_account_id == balance.merchant_account_id
        # Positive proof the row came from the presentment path: the broken branch only fired with
        # a canonical issued amount, which requires a PurchasePresentment (no FX quote involved).
        reason = presentment_backed?(bt)
        return reason unless reason == :ok
      end

      :eligible
    end

    # Refund and dispute legs carry no purchase_id of their own, and a combined-cart dispute
    # carries only charge_id — Dispute#purchases handles both dispute shapes. No reachable
    # purchase (a credit leg, say) means the row cannot be tied to this regression: refuse.
    #
    # For a charge-level dispute this is every purchase on the charge, and only SOME of them
    # can have a presentment row. A charge carries the seller's free/test lines alongside the
    # paid ones (Order::PreparePaymentIntentService#charge_purchases appends them), while the
    # presentment snapshot is built from the paid lines only, because a free line contributes
    # no money to the charge (Charge::PresentmentOrchestrator.persist! writes a row per paid
    # allocation). So a paid EUR line plus a $0 EUR companion is a normal presentment charge
    # with one presentment-backed purchase and one without. Requiring all of them would refuse
    # exactly the rows this repair exists to fix, and tell the operator they were never part of
    # the regression. One presentment-backed purchase is the proof we need: it can only exist
    # if this charge went down the presentment path.
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
      return :bt_purchase_not_presentment unless purchases.any? { |purchase| purchase.purchase_presentment.present? }

      :ok
    end

    def usd?(currency)
      currency.to_s.downcase == Currency::USD
    end

    def skip(balance_id, reason)
      @stats[reason] += 1
      @skipped << { balance_id:, reason: }
    end

    # The live path passes transactions so the summary is built before the rewrite; reading the
    # balance afterwards would record "from usd to usd".
    def correction_summary(balance, transactions = balance.balance_transactions.to_a)
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
