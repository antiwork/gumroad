# frozen_string_literal: true

# Links a seller's Stripe Connect account and retires the Gumroad-managed Stripe account it replaces.
# Retiring that account strands whatever it still owes the seller (payout preparation refuses an
# inactive destination), so a replacement with unsettled obligations is refused before any write.
# Refunds and chargebacks that arrive after the retirement still book to the retired account: they are
# later events, not a race this lock can order.
class StripeConnectAccountLinker
  def self.link(owner:, auth_uid:, stripe_account:)
    new(owner:, auth_uid:, stripe_account:).link
  end

  def initialize(owner:, auth_uid:, stripe_account:)
    @owner = owner
    @auth_uid = auth_uid
    @stripe_account = stripe_account
  end

  # Returns :linked, :linked_elsewhere, :unsettled_obligations, :save_failed or :inactive.
  # Payout claims (Payouts.mark_balances_processing) take the same user lock, so a claim either
  # commits before the check below reads it or waits until the retirement has committed.
  def link
    ApplicationRecord.connected_to(role: :writing) { @owner.with_lock { link_under_lock } }
  end

  private
    def link_under_lock
      # Locked before any plain read so the obligations below see every sale that passed the charge-time check.
      managed_account = @owner.stripe_account(lock: true)
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

      predecessor&.delete_charge_processor_account!
      :linked
    end
end
