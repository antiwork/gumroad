# frozen_string_literal: true

# Links a seller's Stripe Connect account and retires the Gumroad-managed account it replaces, which
# strands whatever that account still owes (payout preparation refuses an inactive destination). A
# replacement with unsettled obligations is refused; anything landing later is reported at the tail.
class StripeConnectAccountLinker
  def self.link(owner:, auth_uid:, stripe_account:)
    new(owner:, auth_uid:, stripe_account:).link
  end

  def initialize(owner:, auth_uid:, stripe_account:)
    @owner = owner
    @auth_uid = auth_uid
    @stripe_account = stripe_account
    @retired_account_id = nil
    @retired_at = nil
  end

  # Returns :linked, :linked_elsewhere, :unsettled_obligations, :save_failed or :inactive.
  # Payout claims (Payouts.mark_balances_processing) take the same user lock, so a claim either commits
  # before the check below reads it or waits until the retirement has committed.
  def link
    result = ApplicationRecord.connected_to(role: :writing) { @owner.with_lock { link_under_lock } }
    enqueue_retired_account_check
    result
  end

  private
    def link_under_lock
      # The obligations read has to follow `with_lock` above: under REPEATABLE READ the first plain
      # read fixes the snapshot, and a snapshot taken before the seller row lock could miss a payout
      # claim that was still in flight.
      managed_account = @owner.stripe_account
      existing = MerchantAccount.where(charge_processor_merchant_id: @auth_uid).alive
                   .find { |merchant_account| merchant_account.is_a_stripe_connect_account? }
      return :linked_elsewhere if existing.present? && existing.user != @owner

      # An already-active link replaces nothing: signing in or replaying the callback leaves the managed
      # account alone, whatever it still owes.
      replacing = !existing&.active?
      predecessor = managed_account if replacing
      return :unsettled_obligations if predecessor&.unsettled_payout_obligations?

      merchant_account = existing || @owner.merchant_accounts.new
      merchant_account.charge_processor_id = StripeChargeProcessor.charge_processor_id
      merchant_account.charge_processor_merchant_id = @auth_uid
      merchant_account.deleted_at = nil
      merchant_account.charge_processor_deleted_at = nil
      merchant_account.charge_processor_alive_at = Time.current
      merchant_account.meta = { "stripe_connect" => "true" }
      return :save_failed unless merchant_account.save

      @owner.check_merchant_account_is_linked = true
      @owner.save!

      merchant_account.currency = @stripe_account.default_currency
      merchant_account.country = @stripe_account.country
      merchant_account.save!

      return :inactive unless merchant_account.active?

      if predecessor
        predecessor.delete_charge_processor_account!
        # Durable re-dispatch marker: a lost enqueue below is recoverable from the row instead of the check
        # being lost with it.
        predecessor.update!(retired_activity_check_pending_at: predecessor.deleted_at.utc.iso8601)
        @retired_account_id = predecessor.id
        @retired_at = predecessor.deleted_at
      end
      :linked
    end

    # After the transaction above commits — a read inside it is pinned to that transaction's snapshot —
    # and delayed, because a sale still settling has not landed yet at the moment it commits.
    def enqueue_retired_account_check
      return if @retired_account_id.nil? || @retired_at.nil?

      AlertOnRetiredManagedAccountActivityJob.perform_in(
        AlertOnRetiredManagedAccountActivityJob::SETTLEMENT_TAIL, @retired_account_id, @retired_at.utc.iso8601
      )
    rescue Redis::BaseError, RedisClient::Error => e
      # The account is linked and the retirement committed, so a lost check must not turn a successful
      # connection into an error page.
      ErrorNotifier.notify(e)
    end
end
