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

  # Accounts per run, at up to 2 Stripe reads and 1 delete each. Skipped accounts stay candidates, so a cursor walks
  # the population.
  MAX_ACCOUNTS_PER_RUN = 30
  MAX_REPORTED = 25
  FEATURE_FLAG = :delete_closed_seller_connect_accounts

  def perform
    after_id = current_cursor
    candidates = candidate_accounts(after_id)
    if candidates.empty? && after_id.positive?
      save_cursor(0)
      candidates = candidate_accounts(0)
    end
    truncated = candidates.size > MAX_ACCOUNTS_PER_RUN
    candidates = candidates.first(MAX_ACCOUNTS_PER_RUN)
    save_cursor(candidates.last.id) if candidates.any?

    live = Feature.active?(FEATURE_FLAG)
    results = candidates.map { |merchant_account| evaluate(merchant_account, live:) }

    return if results.empty? && !truncated

    InternalNotificationWorker.perform_async("payouts", "Closed sellers' Stripe Connect accounts", message_for(results, live:, truncated:))
  end

  private
    def candidate_accounts(after_id)
      candidate_accounts_scope.where("merchant_accounts.id > ?", after_id)
                              .order(id: :asc)
                              .limit(MAX_ACCOUNTS_PER_RUN + 1)
                              .to_a
    end

    def candidate_accounts_scope
      MerchantAccount.stripe
                     .where(user_id: User.deleted.select(:id))
                     .where.not(charge_processor_merchant_id: nil)
                     .where(charge_processor_deleted_at: nil)
                     .where.not(id: MerchantAccount.stripe_connect.select(:id))
                     .not_retired_by_adoption
    end

    def evaluate(merchant_account, live:)
      reason = local_blocker(merchant_account)
      return skipped(merchant_account, reason) if reason

      stripe_account_id = merchant_account.charge_processor_merchant_id
      begin
        stripe_account = Stripe::Account.retrieve(stripe_account_id)
      rescue Stripe::InvalidRequestError => e
        # Only this lookup's resource_missing says the account is gone. The same code from any other
        # call, or any other refusal, is uncertain and falls through to the skip below.
        raise unless e.code == "resource_missing"
        return already_gone(merchant_account, stripe_account_id, live:)
      end
      return skipped(merchant_account, "stripe account type is #{stripe_account[:type].inspect}, not custom") unless stripe_account[:type] == "custom"

      balance = Stripe::Balance.retrieve({}, { stripe_account: stripe_account_id })
      reason = balance_blocker(balance)
      return skipped(merchant_account, reason) if reason

      # Re-check after the Stripe reads: a payout or sale may have started while they ran.
      fresh, reason = final_check(merchant_account, stripe_account_id)
      return skipped(merchant_account, reason) if reason
      return { outcome: :eligible, merchant_account: } unless live

      return skipped(merchant_account, "Stripe did not confirm deletion") unless stripe_account.delete[:deleted] == true

      finish_locally(fresh, "deleted at Stripe")
    rescue => e
      skipped(merchant_account, "#{e.class}: #{e.message}")
    end

    def already_gone(merchant_account, stripe_account_id, live:)
      return { outcome: :eligible, merchant_account:, reason: "already gone at Stripe" } unless live

      fresh, reason = final_check(merchant_account, stripe_account_id)
      return skipped(merchant_account, "already gone at Stripe, but #{reason}") if reason

      finish_locally(fresh, "already gone at Stripe")
    end

    # The Stripe account is gone either way, so a failed local write is reported apart from both
    # deletions and skips. The row stays a candidate and a later run finishes it.
    def finish_locally(merchant_account, stripe_state)
      merchant_account.delete_charge_processor_account!(validate: false)
      { outcome: :deleted, merchant_account: }
    rescue => e
      { outcome: :local_update_failed, merchant_account:, reason: "#{stripe_state}; local update failed: #{e.class}: #{e.message}" }
    end

    # Every available and pending entry must be an explicit zero: a missing, empty or malformed list
    # is not a zero balance.
    def balance_blocker(balance)
      lists = [balance[:available], balance[:pending]]
      well_formed = lists.all? { |list| list.is_a?(Array) && list.any? && list.all? { |entry| entry[:amount].is_a?(Integer) } }
      return "Stripe balance missing or malformed" unless well_formed

      "non-zero Stripe balance" unless lists.sum([]).all? { |entry| entry[:amount].zero? }
    end

    # Reads from the primary and returns the fresh row, so a replica, a cached association or a stale
    # instance can neither hide a change nor be written back over it.
    def final_check(merchant_account, stripe_account_id)
      ApplicationRecord.connected_to(role: :writing) do
        fresh = candidate_accounts_scope.find_by(id: merchant_account.id)
        return [nil, "account is no longer a live candidate"] unless fresh
        return [nil, "account changed during the checks"] unless fresh.user_id == merchant_account.user_id && fresh.charge_processor_merchant_id == stripe_account_id

        [fresh, local_blocker(fresh) || (fresh.unsettled_payout_obligations? ? "seller has unsettled payout obligations" : nil)]
      end
    end

    # Local facts, none of which Stripe can answer.
    def local_blocker(merchant_account)
      user = User.find(merchant_account.user_id)
      return "seller is not closed" unless user.deleted?
      return "seller has a successful or in-progress purchase" if Purchase.where(seller_id: user.id, purchase_state: Purchase::ALL_SUCCESS_STATES + ["in_progress"]).exists?
      return "seller has a payment being created or processed" if user.payments.where(state: [Payment::CREATING, Payment::PROCESSING]).exists?
      return "seller has an unsettled balance on this account" if merchant_account.balances.where(state: %w[unpaid processing]).exists?
      return "seller has an uncommitted balance transaction" if merchant_account.balance_transactions.where(balance_id: nil).exists?
      nil
    end

    def skipped(merchant_account, reason)
      { outcome: :skipped, merchant_account:, reason: }
    end

    def message_for(results, live:, truncated:)
      done = results.select { |r| r[:outcome] == :eligible || r[:outcome] == :deleted }
      unfinished = results.select { |r| r[:outcome] == :local_update_failed }
      skipped = results.select { |r| r[:outcome] == :skipped }

      lines = ["#{live ? "Deleted" : "Eligible for deletion (flag off, nothing deleted)"}: #{done.size}", *report_lines(done)]
      lines.push("Gone at Stripe, local record not updated: #{unfinished.size}", *report_lines(unfinished)) if unfinished.any?
      lines.push("Skipped: #{skipped.size}", *report_lines(skipped))
      lines << "More accounts remain; the next run continues from the cursor." if truncated
      lines.join("\n")
    end

    def report_lines(results)
      results.first(MAX_REPORTED).map { |r| ["  #{r[:merchant_account].charge_processor_merchant_id}", r[:reason]].compact.join(" - ") }
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
