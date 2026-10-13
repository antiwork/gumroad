# frozen_string_literal: true

# Relabels Gumroad-held affiliate-commission balances that were booked in the buyer's currency
# before affiliate credits were booked in USD. The cents were already USD, so only the labels
# change and no amount moves.
#
# Dry run by default. Explicit ids only:
#
#   Onetime::RelabelAffiliateGumroadHeldBalances.new(balance_ids: [...], fix_deployed_at: ...).process
#   Onetime::RelabelAffiliateGumroadHeldBalances.new(balance_ids: [...], fix_deployed_at: ..., dry_run: false).process
class Onetime::RelabelAffiliateGumroadHeldBalances
  attr_reader :stats, :corrected, :skipped

  def initialize(balance_ids:, fix_deployed_at:, dry_run: true, logger: Rails.logger)
    raise ArgumentError, "fix_deployed_at is required: pass the production deployment time of the USD affiliate booking" if fix_deployed_at.blank?

    @balance_ids = balance_ids
    @fix_deployed_at = fix_deployed_at
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

    log "stats: #{@stats.sort_by { |k, _| k.to_s }.to_h.inspect}"
    @skipped.each { |s| log "skipped: #{s.inspect}" }
    { stats: @stats, corrected: @corrected, skipped: @skipped }
  end

  private
    def process_one(balance_id)
      @stats[:scanned] += 1

      balance = Balance.find_by(id: balance_id)
      reason = check_eligibility(balance)
      return skip(balance_id, reason) if reason != :eligible

      if @dry_run
        @stats[:corrected] += 1
        @corrected << summary(balance, balance.balance_transactions.to_a)
        return
      end

      ApplicationRecord.transaction do
        balance = Balance.lock.find(balance_id)
        reason = check_eligibility(balance)
        if reason != :eligible
          skip(balance_id, reason)
          raise ActiveRecord::Rollback
        end

        transactions = balance.balance_transactions.to_a
        entry = summary(balance, transactions)

        transactions.each do |bt|
          log "relabelling BT #{bt.id} (balance #{balance.id}, purchase #{bt.purchase_id}): #{bt.issued_amount_currency}/#{bt.holding_amount_currency} -> usd"
          # update_columns skips the immutability guard: only the label was wrong and the amounts are asserted unchanged.
          bt.update_columns(
            issued_amount_currency: Currency::USD,
            holding_amount_currency: Currency::USD,
            updated_at: Time.current,
          )
        end

        balance.currency = Currency::USD
        balance.holding_currency = Currency::USD
        balance.save!

        @stats[:corrected] += 1
        @corrected << entry
      end
    rescue => e
      @stats[:error] += 1
      @skipped << { balance_id:, reason: :error, error: "#{e.class}: #{e.message}" }
      log "ERROR on balance #{balance_id}: #{e.class}: #{e.message}"
    end

    def check_eligibility(balance)
      return :not_found if balance.nil?

      merchant_account = balance.merchant_account
      return :not_gumroad_held unless merchant_account&.holder_of_funds == HolderOfFunds::GUMROAD
      return :account_not_usd unless usd?(merchant_account.currency)
      return :already_usd if usd?(balance.currency) && usd?(balance.holding_currency)
      return :not_unpaid unless balance.unpaid?
      return :balance_currencies_differ unless balance.currency.to_s == balance.holding_currency.to_s
      return :balance_amounts_differ unless balance.amount_cents == balance.holding_amount_cents

      transactions = balance.balance_transactions.to_a
      return :no_balance_transactions if transactions.empty?
      return :bt_total_mismatch unless transactions.sum(&:issued_amount_net_cents) == balance.amount_cents

      transactions.each do |bt|
        reason = check_transaction(bt, balance)
        return reason if reason != :ok
      end

      :eligible
    end

    def check_transaction(bt, balance)
      return :bt_wrong_merchant_account unless bt.merchant_account_id == balance.merchant_account_id
      # The balance is the affiliate's, so every leg on it must be that same user's: a leg booked
      # to another user is a separate data problem, not a label this repair may rewrite.
      return :bt_wrong_owner unless bt.user_id == balance.user_id
      return :bt_created_after_fix unless bt.created_at < @fix_deployed_at
      return :bt_currencies_differ unless bt.issued_amount_currency.to_s == bt.holding_amount_currency.to_s
      # Compare against the balance, not just the leg against itself: a leg already labelled USD on
      # a non-USD balance would otherwise be reported as repaired while the balance stayed foreign.
      return :bt_currency_differs_from_balance unless bt.issued_amount_currency.to_s == balance.currency.to_s &&
                                                    bt.holding_amount_currency.to_s == balance.holding_currency.to_s
      return :bt_cents_differ unless bt.issued_amount_net_cents == bt.holding_amount_net_cents &&
                                     bt.issued_amount_gross_cents == bt.holding_amount_gross_cents
      return :bt_not_purchase_leg if bt.purchase.nil? || bt.refund_id || bt.dispute_id

      # The commission cents come from the affiliate credit, which is always computed in USD.
      credit = bt.purchase.affiliate_credit
      return :bt_no_affiliate_credit if credit.nil?
      return :bt_not_affiliate_leg unless credit.affiliate_user_id == bt.user_id && bt.purchase.seller_id != bt.user_id
      return :bt_credit_cents_mismatch unless credit.amount_cents == bt.issued_amount_net_cents

      :ok
    end

    def usd?(currency)
      currency.to_s.downcase == Currency::USD
    end

    def skip(balance_id, reason)
      @stats[reason] += 1
      @skipped << { balance_id:, reason: }
    end

    def summary(balance, transactions)
      {
        balance_id: balance.id,
        user_id: balance.user_id,
        from_currency: balance.currency,
        from_holding_currency: balance.holding_currency,
        amount_cents: balance.amount_cents,
        holding_amount_cents: balance.holding_amount_cents,
        balance_transaction_ids: transactions.map(&:id),
      }
    end

    def log(msg)
      @logger.info("[affiliate gumroad-held relabel] #{msg}")
    end
end
