# frozen_string_literal: true

class Onetime::BackfillSelfAffiliateDroppedProceeds
  BUG_INTRODUCED_AT = Time.utc(2026, 4, 28)
  BUG_FIXED_AT = Time.utc(2026, 6, 2)
  REMEDIATION_WINDOW = BUG_INTRODUCED_AT...BUG_FIXED_AT

  ALREADY_CREDITED_PURCHASE_IDS = [
    341462431,
    340779501,
    340326540,
  ].freeze

  SKIP_REASONS = %i[
    missing_affiliate
    not_self_affiliate
    wrong_state
    zero_price
    outside_window
    already_credited
    refunded
    partially_refunded
    chargedback
    not_gumroad_merchant
    missing_seller
    missing_merchant_account
    no_affiliate_credit
    nothing_to_credit
    invalid_total_transaction_cents
    unexpected_bt_count
    bt_wrong_user
    bt_amount_mismatch
    bt_wrong_purchase
    bt_currency_missing
  ].freeze

  attr_reader :stats, :credited, :skipped

  def initialize(dry_run: true, purchase_ids: nil, verbose: false, logger: Rails.logger)
    @dry_run = dry_run
    @purchase_ids = purchase_ids
    @verbose = verbose
    @logger = logger
    @stats = Hash.new(0)
    @credited = []
    @skipped = Hash.new { |h, k| h[k] = [] }
  end

  def process
    log "Starting #{self.class.name} (#{@dry_run ? 'DRY RUN' : 'LIVE'})"
    log "Window: #{BUG_INTRODUCED_AT.iso8601} → #{BUG_FIXED_AT.iso8601}"

    candidate_ids.each do |purchase_id|
      ReplicaLagWatcher.watch unless @dry_run
      process_one(purchase_id)
    end

    print_summary
    { stats: @stats, credited: @credited, skipped: @skipped }
  end

  private
    def candidate_ids
      return @purchase_ids if @purchase_ids

      Purchase
        .joins("INNER JOIN affiliates ON affiliates.id = purchases.affiliate_id")
        .where(created_at: REMEDIATION_WINDOW)
        .where(purchase_state: "successful")
        .where("purchases.price_cents > 0")
        .where.not(id: ALREADY_CREDITED_PURCHASE_IDS)
        .where("affiliates.affiliate_user_id = purchases.seller_id")
        .pluck(:id)
    end

    def process_one(purchase_id)
      @stats[:scanned] += 1

      if @dry_run
        purchase = Purchase.find(purchase_id)
        reason = check_eligibility(purchase)
        if reason == :eligible
          @stats[:credited] += 1
          @credited << credit_summary(purchase)
        else
          @stats[reason] += 1
          @skipped[reason] << purchase_id if @verbose
        end
        return
      end

      new_bt = nil
      purchase = nil

      ApplicationRecord.transaction do
        purchase = Purchase.lock.find(purchase_id)
        reason = check_eligibility(purchase)

        if reason != :eligible
          @stats[reason] += 1
          @skipped[reason] << purchase_id if @verbose
          next
        end

        new_bt = insert_seller_bt!(purchase)
      end

      return unless new_bt

      new_bt.update_balance!
      Purchase.where(id: purchase_id).update_all(purchase_success_balance_id: new_bt.balance_id)
      @stats[:credited] += 1
      @credited << credit_summary(purchase)
    rescue => e
      @stats[:error] += 1
      if new_bt&.balance_id.present?
        @skipped[:error] << {
          purchase_id:,
          error: "#{e.class}: #{e.message}",
          bt_id: new_bt.id,
          balance_id: new_bt.balance_id,
          recovery: "balance already credited; set purchases.purchase_success_balance_id=#{new_bt.balance_id}. " \
                    "DO NOT re-run update_balance! — it would double-credit.",
        }
        @logger.error "[backfill] error on purchase #{purchase_id}: #{e.class}: #{e.message} " \
                      "— BT #{new_bt.id} already linked to balance #{new_bt.balance_id} " \
                      "(seller credited). Only the purchase_success_balance_id FK update failed. " \
                      "Recovery: UPDATE purchases SET purchase_success_balance_id=#{new_bt.balance_id} " \
                      "WHERE id=#{purchase_id}. Do NOT call update_balance! again."
      elsif new_bt
        @skipped[:error] << {
          purchase_id:,
          error: "#{e.class}: #{e.message}",
          orphan_bt_id: new_bt.id,
          recovery: "BT inserted but balance not linked. Inspect seller's Balance for the purchase date " \
                    "before deciding whether to call update_balance! (partial increments may have applied).",
        }
        @logger.error "[backfill] error on purchase #{purchase_id}: #{e.class}: #{e.message} " \
                      "— orphan BT #{new_bt.id} (balance_id IS NULL). " \
                      "Inspect seller_id=#{purchase&.seller_id} Balance for purchase date before recovering."
      else
        @skipped[:error] << { purchase_id:, error: "#{e.class}: #{e.message}" }
        @logger.error "[backfill] error on purchase #{purchase_id}: #{e.class}: #{e.message} " \
                      "(no BT created; safe to retry)"
      end
    end

    def check_eligibility(p)
      return :already_credited if ALREADY_CREDITED_PURCHASE_IDS.include?(p.id)
      return :wrong_state unless p.purchase_state == "successful"
      return :zero_price unless p.price_cents.to_i > 0
      return :outside_window unless REMEDIATION_WINDOW.cover?(p.created_at)
      return :refunded if p.stripe_refunded
      return :partially_refunded if p.stripe_partially_refunded
      return :chargedback if p.chargedback_not_reversed?
      return :not_gumroad_merchant unless p.charged_using_gumroad_merchant_account?

      affiliate = p.affiliate
      return :missing_affiliate if affiliate.nil?
      return :not_self_affiliate unless affiliate.affiliate_user_id == p.seller_id

      return :missing_seller if p.seller.nil?
      return :missing_merchant_account if p.merchant_account.nil?

      return :no_affiliate_credit unless p.affiliate_credit_cents.to_i > 0
      return :invalid_total_transaction_cents unless p.total_transaction_cents.to_i > 0

      missing_net_cents = p.payment_cents.to_i - p.affiliate_credit_cents.to_i
      return :nothing_to_credit unless missing_net_cents > 0

      bts = p.balance_transactions.to_a
      return :unexpected_bt_count unless bts.size == 1

      bt = bts.first
      return :bt_wrong_purchase unless bt.purchase_id == p.id
      return :bt_wrong_user unless bt.user_id == p.seller_id
      return :bt_amount_mismatch unless bt.issued_amount_net_cents == p.affiliate_credit_cents.to_i
      return :bt_currency_missing if bt.issued_amount_currency.blank? || bt.holding_amount_currency.blank?

      :eligible
    end

    def insert_seller_bt!(p)
      existing_bt = p.balance_transactions.first
      missing_net_cents = p.payment_cents.to_i - p.affiliate_credit_cents.to_i

      issued = BalanceTransaction::Amount.new(
        currency: existing_bt.issued_amount_currency,
        gross_cents: p.total_transaction_cents,
        net_cents: missing_net_cents,
      )
      holding = BalanceTransaction::Amount.new(
        currency: existing_bt.holding_amount_currency,
        gross_cents: p.total_transaction_cents,
        net_cents: missing_net_cents,
      )

      BalanceTransaction.create!(
        user: p.seller,
        merchant_account: p.merchant_account,
        purchase: p,
        issued_amount: issued,
        holding_amount: holding,
        update_user_balance: false,
      )
    end

    def credit_summary(p)
      {
        purchase_id: p.id,
        seller_id: p.seller_id,
        price_cents: p.price_cents,
        fee_cents: p.fee_cents,
        affiliate_credit_cents: p.affiliate_credit_cents.to_i,
        credited_cents: p.payment_cents.to_i - p.affiliate_credit_cents.to_i,
      }
    end

    def print_summary
      log "=" * 80
      log "#{self.class.name}: #{@dry_run ? 'DRY RUN' : 'LIVE'}"
      log "=" * 80
      @stats.sort_by { |k, _| k.to_s }.each { |k, v| log "  #{k}: #{v}" }
      total = @credited.sum { |c| c[:credited_cents] }
      unique_sellers = @credited.map { |c| c[:seller_id] }.uniq.size
      log "  total_credit_cents: #{total} (~$#{format('%.2f', total / 100.0)})"
      log "  unique_sellers_credited: #{unique_sellers}"
    end

    def log(msg)
      @logger.info("[backfill] #{msg}")
    end
end
