# frozen_string_literal: true

# Undoes what saving a PayPal address does to a seller's bank rail
# (UpdatePayoutMethod#process_payment_address_params): revives the soft-deleted bank account and
# its Stripe merchant account, and clears the PayPal address so payouts go back to the bank.
#
# Exists for countries where Stripe refuses to create a replacement account (India), so the seller
# cannot rebuild the rail themselves. Same revive shape as StripeMerchantAccountManager.disconnect.
class RestoreBankPayoutRail
  Result = Struct.new(:success, :error, :bank_account, :merchant_account, keyword_init: true)

  def initialize(user:)
    @user = user
  end

  def process
    return Result.new(success: false, error: :bank_account_already_active) if user.active_bank_account.present?

    bank_account = user.bank_accounts.deleted.where.not(type: CardBankAccount.name).order(deleted_at: :desc).first
    return Result.new(success: false, error: :no_deleted_bank_account) if bank_account.nil?

    merchant_account = user.merchant_accounts.stripe.deleted
      .where(charge_processor_merchant_id: bank_account.stripe_connect_account_id)
      .find { |ma| !ma.is_a_stripe_connect_account? }
    return Result.new(success: false, error: :no_deleted_merchant_account) if merchant_account.nil? || merchant_account.charge_processor_merchant_id.blank?

    # Confirm Stripe still has the account before pointing payouts at it: MerchantAccount#delete_charge_processor_account!
    # only marks our row, but a rejected/closed account on Stripe's side would make the revived rail unpayable.
    stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
    return Result.new(success: false, error: :stripe_account_unavailable) if stripe_account.respond_to?(:deleted) && stripe_account.deleted

    user.with_lock do
      merchant_account.deleted_at = merchant_account.charge_processor_deleted_at = nil
      merchant_account.charge_processor_alive_at = Time.current
      merchant_account.save!

      bank_account.deleted_at = nil
      bank_account.save!(validate: false)

      user.update!(payment_address: "", invalidated_paypal_payout_address: nil) if user.payment_address.present? || user.invalidated_paypal_payout_address.present?
    end

    Result.new(success: true, bank_account:, merchant_account:)
  end

  private
    attr_reader :user
end
