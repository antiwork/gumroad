# frozen_string_literal: true

# Links a seller's Stripe Connect account and retires the Gumroad-managed Stripe account it replaces.
# Retiring it strands whatever it still owes the seller (payout preparation refuses an inactive
# destination), so a replacement with unsettled obligations is refused before any write. A sale that
# settles late, a refund or a chargeback, is reported at the settlement tail instead.
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
  # Payout claims (Payouts.mark_balances_processing) take the same user lock, so a claim either
  # commits before the check below reads it or waits until the retirement has committed.
  def link
    result = ApplicationRecord.connected_to(role: :writing) { @owner.with_lock { link_under_lock } }
    enqueue_retired_account_check
    result
  end

  private
    def link_under_lock
      # `with_lock` above holds the seller row, which is the lock a payout claim takes
      # (Payouts.mark_balances_processing), so a claim either committed before the obligations read below
      # or waits until this retirement has committed. The read has to follow that lock: under
      # REPEATABLE READ the first plain read fixes the snapshot, and a snapshot taken earlier could
      # miss a claim that was still in flight.
      managed_account = @owner.stripe_account
      existing = MerchantAccount.where(charge_processor_merchant_id: @auth_uid).alive
                   .find { |merchant_account| merchant_account.is_a_stripe_connect_account? }
      return :linked_elsewhere if existing.present? && existing.user != @owner

      # An already-active link replaces nothing: signing in or replaying the callback leaves any
      # managed account alone, whatever it still owes.
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
        # Durable re-dispatch marker: if the enqueue below is lost, the sweep re-derives this
        # retirement from the row instead of the check being lost with the enqueue.
        predecessor.update!(retired_activity_check_pending_at: predecessor.deleted_at.utc.iso8601)
        @retired_account_id = predecessor.id
        @retired_at = predecessor.deleted_at
      end
      :linked
    end

    # Enqueued after the transaction above has committed. The delay is the point: a read inside the
    # transaction is pinned to the snapshot the obligations read established, and one right after it
    # commits still runs ahead of a sale that has not settled yet.
    def enqueue_retired_account_check
      return if @retired_account_id.nil? || @retired_at.nil?

      AlertOnRetiredManagedAccountActivityJob.perform_in(
        AlertOnRetiredManagedAccountActivityJob::SETTLEMENT_TAIL, @retired_account_id, @retired_at.utc.iso8601
      )
    rescue Redis::BaseError, RedisClient::Error => e
      # The seller's account is already linked and the retirement already committed; a lost check
      # must not turn a successful connection into an error page.
      ErrorNotifier.notify(e)
    end
end
