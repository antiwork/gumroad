# frozen_string_literal: true

# Repairs the balances stranded by the June 3 2026 run of
# Onetime::BackfillSelfAffiliateDroppedProceeds (see gumroad-private#1000).
#
# That run copied the holding currency from each purchase's affiliate-leg balance
# transaction, which is always USD, onto the seller-leg transaction it created. For
# sellers whose Stripe account settles in another currency (GBP, EUR, CAD, ...) this
# produced Balance rows labeled as holding USD on a non-USD account. Payout runs refuse
# to touch a balance whose holding currency does not match the account it would be paid
# from, so the money has sat in "unpaid" ever since. Nothing was ever over- or under-paid
# — the mislabeled balances were consistently excluded — so the repair is purely to
# relabel them with their true settlement currency and amounts, after which they become
# eligible for the next scheduled payout.
#
# For each affected balance this service:
#   1. Re-fetches the charge from the processor to recover the real settlement currency
#      and amounts (the same way the fixed backfill now books them; network calls happen
#      before any row locks are taken).
#   2. Corrects the holding fields on each mislabeled balance transaction in place.
#      Balance transactions are normally immutable, and the usual way to change one is
#      to soft-delete it and write a corrected copy — but this table has no deleted_at
#      column, so that flow cannot work here. Writing the columns directly (bypassing
#      the immutability guard) is deliberate: the rows' holding fields were wrong from
#      the moment they were written, and the original values are preserved in the run's
#      log output and on the tracking issue.
#   3. Updates the balance itself: holding currency becomes the merchant account's
#      currency and the held amount becomes the sum of the corrected settlement amounts.
#      The USD-issued amount (what the seller earned, and what payout math is based on)
#      is untouched.
#
# Usage (dry run by default; balance ids must be passed explicitly — this service
# deliberately has no "find everything that looks wrong" mode, the affected set was
# enumerated and reviewed on the issue):
#
#   Onetime::CorrectSelfAffiliateBackfillHoldingCurrency.new(balance_ids: [...]).process
#   Onetime::CorrectSelfAffiliateBackfillHoldingCurrency.new(balance_ids: [...], dry_run: false).process
#
class Onetime::CorrectSelfAffiliateBackfillHoldingCurrency
  include Onetime::RebuildsSellerSettlementAmounts

  # The 20-minute window in which the June 3 backfill wrote its balance transactions.
  # Used as a guard so this service refuses to touch transactions from any other source.
  BACKFILL_WINDOW = Time.utc(2026, 6, 3, 12, 0)..Time.utc(2026, 6, 3, 12, 20)

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

      # Recover the real settlement amounts for every transaction on this balance
      # BEFORE opening the database transaction — these are network calls to the charge
      # processor and must not run while we hold row locks. Eligibility is re-checked
      # under lock below in case anything changed in between.
      expected_currency = balance.merchant_account.currency
      corrections = balance.balance_transactions.map do |bt|
        holding = seller_holding_amount(bt.purchase)
        if holding.currency.to_s.downcase != expected_currency.to_s.downcase
          raise "Rebuilt settlement currency #{holding.currency.inspect} for purchase #{bt.purchase_id} " \
                "does not match merchant account currency #{expected_currency.inspect} — refusing to relabel"
        end
        [bt, holding]
      end

      if @dry_run
        @stats[:corrected] += 1
        @corrected << correction_summary(balance, corrections)
        return
      end

      ApplicationRecord.transaction do
        balance = Balance.lock.find(balance_id)
        reason = check_eligibility(balance)
        if reason != :eligible
          skip(balance_id, reason)
          raise ActiveRecord::Rollback
        end

        corrections.each do |bt, holding|
          # Log the wrong values before overwriting them — with no deleted_at column on
          # this table there is no soft-deleted original to fall back on, so this log
          # line (plus the tracking issue) is the audit trail.
          log "correcting BT #{bt.id} (balance #{balance.id}, purchase #{bt.purchase_id}): " \
              "holding #{bt.holding_amount_currency} gross=#{bt.holding_amount_gross_cents} net=#{bt.holding_amount_net_cents} " \
              "-> #{holding.currency} gross=#{holding.gross_cents} net=#{holding.net_cents}"
          # update_columns skips the Immutable guard on purpose; see the class comment.
          bt.update_columns(
            holding_amount_currency: holding.currency,
            holding_amount_gross_cents: holding.gross_cents,
            holding_amount_net_cents: holding.net_cents,
            updated_at: Time.current,
          )
        end

        balance.holding_currency = expected_currency
        balance.holding_amount_cents = corrections.sum { |_, holding| holding.net_cents }
        balance.save!

        @stats[:corrected] += 1
        @corrected << correction_summary(balance, corrections)
      end
    rescue => e
      @stats[:error] += 1
      @skipped << { balance_id:, reason: :error, error: "#{e.class}: #{e.message}" }
      log "ERROR on balance #{balance_id}: #{e.class}: #{e.message}"
    end

    def check_eligibility(balance)
      return :not_found if balance.nil?
      # Already-corrected balances land here, which makes re-runs after a partial
      # failure safe: fixed rows are skipped, not double-corrected.
      return :holding_currency_matches_account if balance.holding_currency.to_s.downcase == balance.merchant_account.currency.to_s.downcase
      return :not_usd_labeled unless balance.holding_currency.to_s.downcase == Currency::USD
      # Amounts on a balance are only changeable while it is unpaid. Anything else means
      # a payout has picked it up since the affected set was enumerated — investigate
      # rather than touch.
      return :not_unpaid unless balance.unpaid?

      bts = balance.balance_transactions.to_a
      return :no_balance_transactions if bts.empty?

      bts.each do |bt|
        # Only purchase-linked seller-leg rows written inside the backfill's own window
        # may be relabeled. A transaction from any other source sharing the balance means
        # the enumeration missed something — leave the whole balance alone and flag it.
        return :bt_not_purchase_linked if bt.purchase_id.nil?
        return :bt_outside_backfill_window unless BACKFILL_WINDOW.cover?(bt.created_at)
        return :bt_wrong_user unless bt.user_id == bt.purchase&.seller_id
        return :bt_not_usd_labeled unless bt.holding_amount_currency.to_s.downcase == Currency::USD
        # The settlement rebuild reads the purchase's merchant account while the balance
        # pays out from its own. For backfill rows these are the same account by
        # construction, but if a purchase has since been repointed to a different account
        # (even one in the same currency) we would relabel using settlement data from the
        # wrong account — refuse instead.
        return :bt_wrong_merchant_account unless bt.merchant_account_id == balance.merchant_account_id &&
          bt.purchase.merchant_account_id == balance.merchant_account_id
      end

      :eligible
    end

    def skip(balance_id, reason)
      @stats[reason] += 1
      @skipped << { balance_id:, reason: }
    end

    def correction_summary(balance, corrections)
      {
        balance_id: balance.id,
        user_id: balance.user_id,
        holding_currency: balance.merchant_account.currency,
        amount_cents: balance.amount_cents,
        corrected_holding_amount_cents: corrections.sum { |_, holding| holding.net_cents },
        balance_transaction_ids: corrections.map { |bt, _| bt.id },
      }
    end

    def print_summary
      log "=" * 80
      log "#{self.class.name}: #{@dry_run ? 'DRY RUN' : 'LIVE'}"
      log "=" * 80
      @stats.sort_by { |k, _| k.to_s }.each { |k, v| log "  #{k}: #{v}" }
      log "  sellers_affected: #{@corrected.map { |c| c[:user_id] }.uniq.size}"
      @skipped.each { |s| log "  skipped: #{s.inspect}" }
    end

    def log(msg)
      @logger.info("[holding-currency correction] #{msg}")
    end
end
