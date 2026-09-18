# frozen_string_literal: true

# Reverses the bank-rail deletion a PayPal switch performs, for sellers whose country cannot
# re-create one (User#can_create_bank_payout_rail?). Elsewhere the seller just re-adds a bank account.
class RestoreBankPayoutRail
  Result = Struct.new(:success, :error, :bank_account, :merchant_account, keyword_init: true)

  def initialize(user:)
    @user = user
  end

  def process
    checked_compliance_attributes = user.alive_user_compliance_info&.attributes
    return Result.new(success: false, error: :rail_recreatable) if user.can_create_bank_payout_rail?

    bank_account, merchant_account, error = locate
    return Result.new(success: false, error:) if error

    checked_bank_attributes = bank_account.attributes
    checked_merchant_attributes = merchant_account.attributes
    stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
    return Result.new(success: false, error: :stripe_account_unavailable) unless payable?(stripe_account)
    unless stripe_account.respond_to?(:country) && stripe_account.country == merchant_account.country
      return Result.new(success: false, error: :incompatible_bank_rail)
    end

    result = nil
    user.with_lock do
      # Country and compliance updates share this lock. Never apply a provider check to a
      # different local rail or compliance revision than the one it was requested for.
      if user.can_create_bank_payout_rail?
        next result = Result.new(success: false, error: :rail_recreatable)
      end
      if user.alive_user_compliance_info&.attributes != checked_compliance_attributes
        next result = Result.new(success: false, error: :payout_rail_changed)
      end
      bank_account, merchant_account, error = locate(bank_account:, merchant_account:, lock: true)
      if !error && (bank_account.attributes != checked_bank_attributes || merchant_account.attributes != checked_merchant_attributes)
        error = :payout_rail_changed
      end
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

    def locate(bank_account: nil, merchant_account: nil, lock: false)
      return [nil, nil, :bank_account_already_active] if user.bank_accounts.alive.exists?

      bank_account = if bank_account
        user.bank_accounts.deleted.lock(lock).find_by(id: bank_account.id)
      else
        user.bank_accounts.deleted.where.not(type: CardBankAccount.name).order(deleted_at: :desc).first
      end
      return [nil, nil, :no_deleted_bank_account] if bank_account.nil?

      merchant_account ||= user.merchant_accounts.stripe.deleted
        .where(charge_processor_merchant_id: bank_account.stripe_connect_account_id)
        .find { |ma| !ma.is_a_stripe_connect_account? }
      merchant_account = user.merchant_accounts.deleted.lock(lock).find_by(id: merchant_account.id) if merchant_account
      return [nil, nil, :no_deleted_merchant_account] if merchant_account.nil? || merchant_account.charge_processor_merchant_id.blank?
      country = user.alive_user_compliance_info&.legal_entity_country_code
      unless country.present? && bank_account.country == country && merchant_account.country == country
        return [nil, nil, :incompatible_bank_rail]
      end
      return [nil, nil, :not_removed_by_paypal_switch] unless deleted_together?(bank_account, merchant_account)
      # Country changes delete the same pair, and a later return to the original country
      # does not make that retired legal entity's rail safe to restore.
      if user.comments.where(comment_type: Comment::COMMENT_TYPE_COUNTRY_CHANGED)
          .where("created_at >= ?", [bank_account.created_at, merchant_account.created_at].compact.min).exists?
        return [nil, nil, :not_removed_by_paypal_switch]
      end

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
