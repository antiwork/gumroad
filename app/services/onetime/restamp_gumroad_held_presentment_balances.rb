# frozen_string_literal: true

# Relabels unpaid Gumroad-held balances whose holding currency is not USD. Gumroad-held holding
# fields are the canonical USD record of what Gumroad owes the user, and both payout processors
# reject non-USD Gumroad-held balances — Stripe fails the user's whole payment with
# `currency_mismatch`, PayPal silently drops the row.
#
# Two write paths produced these rows, and each transaction must be positively traced to one of
# them before it is touched:
#
#   :presentment — seller rows from buyer-currency presentment charges (fixed by #6505). Only the
#     holding label and gross were wrong; the row's own issued_amount_* fields are the canonical
#     USD figures, so those are copied across.
#
#   :affiliate_credit — affiliate rows on direct charges into a seller's non-USD connected account.
#     The affiliate helpers took their currency from the charge's application-fee settlement
#     currency, so BOTH the issued and holding sides were labelled e.g. EUR. The cents were never
#     converted: they are the purchase's AffiliateCredit#amount_cents, which is computed in USD.
#     The repair writes that recorded USD figure to both sides and asserts it equals the cents
#     already on the row. No exchange rate is used or inferred.
#
# Any other shape is refused. Relabelling must not move a cent: the balance's stored totals must
# equal the re-derived USD total, or the balance is refused.
#
# Dry run by default. Explicit ids only; `candidate_balance_ids` lists what to review:
#
#   ids = Onetime::RestampGumroadHeldPresentmentBalances.candidate_balance_ids
#   Onetime::RestampGumroadHeldPresentmentBalances.new(balance_ids: ids, fix_deployed_at: ..., affiliate_fix_deployed_at: ...).process
#   Onetime::RestampGumroadHeldPresentmentBalances.new(balance_ids: ids, fix_deployed_at: ..., affiliate_fix_deployed_at: ..., dry_run: false).process
#
# Both cutoffs are production deploy times (from the release, not the merge) of the fix for that
# path. A transaction written after its path's fix deployed means the cutoff or the fix is wrong,
# and the balance is refused.
class Onetime::RestampGumroadHeldPresentmentBalances
  # A day before the earliest mislabelled row (2026-07-23 21:07 UTC, when the ramp hit 100%).
  REGRESSION_WINDOW_START = Time.utc(2026, 7, 22, 0, 0)

  # The late edge is #6505's actual production deploy time — from the release that contains it,
  # not the merge. Deployed code cannot write these rows, so a transaction after this instant
  # means the cutoff or the fix is wrong, and the balance is refused rather than relabelled.
  def self.regression_window(fix_deployed_at)
    REGRESSION_WINDOW_START..fix_deployed_at
  end

  # Every unpaid Gumroad-held balance labelled with a non-USD holding currency.
  def self.candidate_balance_ids
    gumroad_held_ids = MerchantAccount.where(user_id: nil).select { |account| account.holder_of_funds == HolderOfFunds::GUMROAD }.map(&:id)
    Balance.unpaid.where(merchant_account_id: gumroad_held_ids).where.not(holding_currency: Currency::USD).order(:id).pluck(:id)
  end

  attr_reader :stats, :corrected, :skipped

  def initialize(balance_ids:, fix_deployed_at:, affiliate_fix_deployed_at:, dry_run: true, logger: Rails.logger)
    raise ArgumentError, "fix_deployed_at is required: pass #6505's production deployment time" if fix_deployed_at.blank?
    raise ArgumentError, "fix_deployed_at #{fix_deployed_at} precedes the regression window start" if fix_deployed_at <= REGRESSION_WINDOW_START
    raise ArgumentError, "affiliate_fix_deployed_at is required: pass the affiliate currency fix's production deployment time" if affiliate_fix_deployed_at.blank?

    @balance_ids = balance_ids
    @regression_window = self.class.regression_window(fix_deployed_at)
    @affiliate_fix_deployed_at = affiliate_fix_deployed_at
    @dry_run = dry_run
    @logger = logger
    @stats = Hash.new(0)
    @corrected = []
    @skipped = []
  end

  def process
    log "Starting #{self.class.name} (#{@dry_run ? 'DRY RUN' : 'LIVE'}) for #{@balance_ids.size} balances"
    log "Presentment window: #{@regression_window.first} .. #{@regression_window.last} (#6505 deployment)"
    log "Affiliate cutoff: #{@affiliate_fix_deployed_at}"

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
          target = usd_target(bt)
          # balance_transactions has no deleted_at, so this log line is the audit trail.
          log "restamping BT #{bt.id} (balance #{balance.id}, purchase #{bt.purchase_id}, #{provenance(bt)}): " \
              "issued #{bt.issued_amount_currency} gross=#{bt.issued_amount_gross_cents} net=#{bt.issued_amount_net_cents}, " \
              "holding #{bt.holding_amount_currency} gross=#{bt.holding_amount_gross_cents} net=#{bt.holding_amount_net_cents} " \
              "-> usd #{target.inspect}"

          # update_columns skips the immutability guard deliberately: these fields were wrong from
          # the moment they were written, and the replacements are the row's own recorded USD figures.
          bt.update_columns(**target, updated_at: Time.current)
        end

        # Only the labels change; the totals were asserted equal above.
        total = transactions.sum { |bt| usd_target(bt)[:holding_amount_net_cents] }
        balance.currency = Currency::USD
        balance.amount_cents = total
        balance.holding_currency = Currency::USD
        balance.holding_amount_cents = total
        balance.save!

        @stats[:corrected] += 1
        @corrected << summary
      end
    rescue => e
      @stats[:error] += 1
      @skipped << { balance_id:, reason: :error, error: "#{e.class}: #{e.message}" }
      log "ERROR on balance #{balance_id}: #{e.class}: #{e.message}"
    end

    # Relabelling must not move a cent: if the USD total re-derived from the rows disagrees with
    # either stored total, this is not a pure label fix — refuse.
    def assert_amounts_unchanged!(balance, transactions)
      rederived = transactions.sum { |bt| usd_target(bt)[:holding_amount_net_cents] }
      return if rederived == balance.holding_amount_cents && rederived == balance.amount_cents

      raise "Balance #{balance.id}: re-derived USD amount #{rederived} != stored holding " \
            "#{balance.holding_amount_cents} / amount #{balance.amount_cents} — refusing to relabel, this is not a pure label fix"
    end

    # The USD figures a transaction is rewritten to. Only called for transactions that passed
    # eligibility, so the provenance is already proven.
    def usd_target(bt)
      if provenance(bt) == :affiliate_credit
        # AffiliateCredit#amount_cents is the purchase's recorded USD figure for this credit.
        cents = bt.purchase.affiliate_credit.amount_cents
        {
          issued_amount_currency: Currency::USD, issued_amount_gross_cents: cents, issued_amount_net_cents: cents,
          holding_amount_currency: Currency::USD, holding_amount_gross_cents: cents, holding_amount_net_cents: cents,
        }
      else
        {
          holding_amount_currency: bt.issued_amount_currency,
          holding_amount_gross_cents: bt.issued_amount_gross_cents,
          holding_amount_net_cents: bt.issued_amount_net_cents,
        }
      end
    end

    # A purchase leg that credits the purchase's affiliate is the affiliate path; everything
    # else must prove the presentment path.
    def provenance(bt)
      affiliate_credit = bt.purchase&.affiliate_credit
      return :affiliate_credit if affiliate_credit && bt.user_id == affiliate_credit.affiliate_user_id && bt.user_id != bt.purchase.seller_id

      :presentment
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
        return :bt_wrong_merchant_account unless bt.merchant_account_id == balance.merchant_account_id
        # Balances are keyed on holding currency, so every row should share the balance's label.
        return :bt_currency_disagrees_with_balance unless bt.holding_amount_currency.to_s.downcase == balance.holding_currency.to_s.downcase

        reason = provenance(bt) == :affiliate_credit ? affiliate_credit_eligibility(bt, balance) : presentment_eligibility(bt)
        return reason unless reason == :ok
      end

      :eligible
    end

    def presentment_eligibility(bt)
      # The issued side is what gets copied, so it must be the canonical USD amount.
      return :bt_issued_not_usd unless usd?(bt.issued_amount_currency)
      # The broken branch passed issued_net_cents straight through as the holding net, so a row
      # where these disagree came from something else and copying would move money.
      return :bt_net_mismatch unless bt.holding_amount_net_cents == bt.issued_amount_net_cents
      return :bt_outside_regression_window unless @regression_window.cover?(bt.created_at)
      # Positive proof the row came from the presentment path: the broken branch only fired with
      # a canonical issued amount, which requires a PurchasePresentment (no FX quote involved).
      presentment_backed?(bt)
    end

    # The affiliate helpers wrote the credit's USD cents verbatim under the settlement currency's
    # label, on both sides. Anything else is not that bug, so it is refused.
    def affiliate_credit_eligibility(bt, balance)
      return :bt_affiliate_after_fix unless bt.created_at <= @affiliate_fix_deployed_at
      return :bt_affiliate_labels_disagree unless bt.issued_amount_currency.to_s.downcase == bt.holding_amount_currency.to_s.downcase
      return :bt_affiliate_balance_currency_disagrees unless balance.currency.to_s.downcase == bt.issued_amount_currency.to_s.downcase

      recorded_usd_cents = bt.purchase.affiliate_credit.amount_cents
      amounts = [bt.issued_amount_gross_cents, bt.issued_amount_net_cents, bt.holding_amount_gross_cents, bt.holding_amount_net_cents]
      # The cents must already be the recorded USD figure; if they were ever converted, relabelling
      # would change the value owed.
      return :bt_affiliate_amount_not_recorded_usd unless amounts.all? { |cents| cents == recorded_usd_cents }

      :ok
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
        from_currency: balance.currency,
        from_holding_currency: balance.holding_currency,
        to_holding_currency: Currency::USD,
        amount_cents: balance.amount_cents,
        holding_amount_cents: balance.holding_amount_cents,
        rederived_holding_amount_cents: transactions.sum { |bt| usd_target(bt)[:holding_amount_net_cents] },
        balance_transaction_ids: transactions.map(&:id),
        provenances: transactions.map { |bt| provenance(bt) }.uniq,
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
      @logger.info("[gumroad-held restamp] #{msg}")
    end
end
