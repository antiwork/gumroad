# frozen_string_literal: true

# Closing a seller never reaches Stripe, so a Gumroad-managed custom Connect account outlives them
# (gumroad-private#4250). Finds those accounts, re-checks every guard live, and reports them. It only
# deletes at Stripe while the `delete_closed_seller_connect_accounts` flag is on.
#
# Anything that fails or cannot be established is skipped and reported, never deleted.
class SweepClosedSellerConnectAccountsJob
  include Sidekiq::Job
  include RecurringLockTtl

  sidekiq_options retry: 2, queue: :low, lock: :until_executed
  recurring_lock_ttl max_attempt: 30.minutes

  # Stripe reads per run. Skipped accounts stay candidates, so a cursor walks the population.
  MAX_CANDIDATES_PER_RUN = 100
  MAX_REPORTED = 25
  FEATURE_FLAG = :delete_closed_seller_connect_accounts

  def perform
    after_id = current_cursor
    candidates = candidate_accounts(after_id)
    if candidates.empty? && after_id.positive?
      save_cursor(0)
      candidates = candidate_accounts(0)
    end
    truncated = candidates.size > MAX_CANDIDATES_PER_RUN
    candidates = candidates.first(MAX_CANDIDATES_PER_RUN)
    save_cursor(candidates.last.id) if candidates.any?

    live = Feature.active?(FEATURE_FLAG)
    results = candidates.map { |merchant_account| evaluate(merchant_account, live:) }

    eligible = results.select { |r| r[:outcome] == :eligible || r[:outcome] == :deleted }
    skipped = results.select { |r| r[:outcome] == :skipped }
    return if eligible.empty? && skipped.empty? && !truncated

    InternalNotificationWorker.perform_async("payouts", "Closed sellers' Stripe Connect accounts", message_for(eligible:, skipped:, live:, truncated:))
  end

  private
    def candidate_accounts(after_id)
      MerchantAccount.stripe
                     .where(user_id: User.deleted.select(:id))
                     .where.not(charge_processor_merchant_id: nil)
                     .where(charge_processor_deleted_at: nil)
                     .where.not(id: MerchantAccount.stripe_connect.select(:id))
                     .not_retired_by_adoption
                     .where("merchant_accounts.id > ?", after_id)
                     .order(id: :asc)
                     .limit(MAX_CANDIDATES_PER_RUN + 1)
                     .to_a
    end

    def evaluate(merchant_account, live:)
      reason = local_blocker(merchant_account)
      return skipped(merchant_account, reason) if reason

      stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
      return skipped(merchant_account, "stripe account type is #{stripe_account.type.inspect}, not custom") unless stripe_account.type == "custom"

      balance = Stripe::Balance.retrieve({}, { stripe_account: merchant_account.charge_processor_merchant_id })
      amounts = (balance.available.to_a + balance.pending.to_a).map(&:amount)
      return skipped(merchant_account, "non-zero Stripe balance") unless amounts.all?(&:zero?)

      # Re-check after the Stripe reads: a payout or sale may have started while they ran.
      reason = local_blocker(merchant_account)
      return skipped(merchant_account, reason) if reason

      return { outcome: :eligible, merchant_account: } unless live

      deleted = merchant_account.charge_processor_delete!
      return skipped(merchant_account, "Stripe did not confirm deletion") unless deleted

      merchant_account.delete_charge_processor_account!(validate: false)
      { outcome: :deleted, merchant_account: }
    rescue Stripe::InvalidRequestError => e
      if e.code == "resource_missing" || e.message.to_s.match?(/does not exist|no such account/i)
        # Already gone at Stripe: only our record is stale, and re-running finishes it.
        merchant_account.delete_charge_processor_account!(validate: false) if live
        { outcome: live ? :deleted : :eligible, merchant_account: }
      else
        skipped(merchant_account, "#{e.class}: #{e.message}")
      end
    rescue => e
      skipped(merchant_account, "#{e.class}: #{e.message}")
    end

    # Local facts, none of which Stripe can answer.
    def local_blocker(merchant_account)
      user = merchant_account.user
      return "seller is not closed" unless user.deleted?
      return "seller has a successful or in-progress purchase" if Purchase.where(seller_id: user.id, purchase_state: Purchase::ALL_SUCCESS_STATES + ["in_progress"]).exists?
      return "seller has a payment being created or processed" if user.payments.where(state: [Payment::CREATING, Payment::PROCESSING]).exists?
      return "seller has an unsettled balance on this account" if merchant_account.balances.where(state: %w[unpaid processing]).exists?
      nil
    end

    def skipped(merchant_account, reason)
      { outcome: :skipped, merchant_account:, reason: }
    end

    def message_for(eligible:, skipped:, live:, truncated:)
      lines = []
      verb = live ? "Deleted" : "Eligible for deletion (flag off, nothing deleted)"
      lines << "#{verb}: #{eligible.size}"
      eligible.first(MAX_REPORTED).each { |r| lines << "  #{r[:merchant_account].charge_processor_merchant_id}" }
      lines << "Skipped: #{skipped.size}"
      skipped.first(MAX_REPORTED).each { |r| lines << "  #{r[:merchant_account].charge_processor_merchant_id} - #{r[:reason]}" }
      lines << "More accounts remain; the next run continues from the cursor." if truncated
      lines.join("\n")
    end

    def current_cursor
      $redis.get(RedisKey.closed_seller_connect_sweep_cursor).to_i
    rescue => e
      ErrorNotifier.notify(e)
      0
    end

    def save_cursor(cursor_id)
      $redis.set(RedisKey.closed_seller_connect_sweep_cursor, cursor_id)
    rescue => e
      ErrorNotifier.notify(e)
    end
end
