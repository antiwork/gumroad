# frozen_string_literal: true

# Reverses the bank-rail deletion a PayPal switch performs, for sellers whose country cannot
# re-create one (User#can_create_bank_payout_rail?). Elsewhere the seller just re-adds a bank account.
class RestoreBankPayoutRail
  Result = Struct.new(:success, :error, :bank_account, :merchant_account, keyword_init: true)

  def initialize(user:)
    @user = user
  end

  def process
    return Result.new(success: false, error: :rail_recreatable) if user.can_create_bank_payout_rail?

    bank_account, merchant_account, error = locate
    return Result.new(success: false, error:) if error

    stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
    return Result.new(success: false, error: :stripe_account_unavailable) unless payable?(stripe_account)

    result = nil
    user.with_lock do
      # Re-read under the lock: a bank-account save or a concurrent restore can land between the
      # checks above and here, and reviving on top of it would leave two live bank accounts.
      _, _, error = locate(bank_account:, merchant_account:)
      if error
        result = Result.new(success: false, error:)
      else
        merchant_account.deleted_at = merchant_account.charge_processor_deleted_at = nil
        merchant_account.charge_processor_alive_at = Time.current
        merchant_account.save!

        bank_account.deleted_at = nil
        bank_account.save!(validate: false)

        user.update!(payment_address: "", invalidated_paypal_payout_address: nil) if user.payment_address.present? || user.invalidated_paypal_payout_address.present?
        result = Result.new(success: true, bank_account:, merchant_account:)
      end
    end
    result
  end

  private
    attr_reader :user

    # Returns [bank_account, merchant_account, error]. Restores only the pair the PayPal switch
    # removed together: other flows (country change, payout recovery) also soft-delete bank rows,
    # and those must not come back.
    def locate(bank_account: nil, merchant_account: nil)
      return [nil, nil, :bank_account_already_active] if user.bank_accounts.alive.exists?

      bank_account = if bank_account
        user.bank_accounts.deleted.find_by(id: bank_account.id)
      else
        user.bank_accounts.deleted.where.not(type: CardBankAccount.name).order(deleted_at: :desc).first
      end
      return [nil, nil, :no_deleted_bank_account] if bank_account.nil?

      merchant_account ||= user.merchant_accounts.stripe.deleted
        .where(charge_processor_merchant_id: bank_account.stripe_connect_account_id)
        .find { |ma| !ma.is_a_stripe_connect_account? }
      merchant_account = user.merchant_accounts.deleted.find_by(id: merchant_account.id) if merchant_account
      return [nil, nil, :no_deleted_merchant_account] if merchant_account.nil? || merchant_account.charge_processor_merchant_id.blank?
      return [nil, nil, :not_removed_by_paypal_switch] unless deleted_together?(bank_account, merchant_account)

      [bank_account, merchant_account, nil]
    end

    def deleted_together?(bank_account, merchant_account)
      bank_account.deleted_at.present? && merchant_account.charge_processor_deleted_at.present? &&
        (bank_account.deleted_at - merchant_account.charge_processor_deleted_at).abs <= 1.minute
    end

    # Retrievable is not payable: a rejected or restricted account is still returned by Stripe.
    def payable?(stripe_account)
      return false if stripe_account.respond_to?(:deleted) && stripe_account.deleted
      return false if stripe_account.respond_to?(:requirements) && stripe_account.requirements&.disabled_reason.present?

      !stripe_account.respond_to?(:payouts_enabled) || stripe_account.payouts_enabled != false
    end
end
