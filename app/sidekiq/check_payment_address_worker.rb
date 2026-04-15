# frozen_string_literal: true

class CheckPaymentAddressWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user&.can_flag_for_fraud?

    should_flag = payment_address_matches_suspended_account?(user) ||
                  stripe_fingerprint_matches_suspended_account?(user)

    user.flag_for_fraud!(author_name: "CheckPaymentAddress") if should_flag
  end

  private
    def payment_address_matches_suspended_account?(user)
      return false if user.payment_address.blank?

      banned_accounts_with_same_payment_address = User.where(
        payment_address: user.payment_address,
        user_risk_state: User::Risk::SUSPENDED_STATES
      )

      blocked_email = BlockedObject.find_active_object(user.payment_address)

      banned_accounts_with_same_payment_address.exists? || blocked_email.present?
    end

    def stripe_fingerprint_matches_suspended_account?(user)
      fingerprints = user.alive_bank_accounts.where.not(stripe_fingerprint: [nil, ""]).distinct.pluck(:stripe_fingerprint)
      return false if fingerprints.empty?

      suspended_accounts_with_same_fingerprint = BankAccount
        .joins(:user)
        .where(stripe_fingerprint: fingerprints)
        .where.not(user_id: user.id)
        .where(users: { user_risk_state: User::Risk::SUSPENDED_STATES })

      return true if suspended_accounts_with_same_fingerprint.exists?

      BlockedObject.find_active_objects(fingerprints).present?
    end
end
