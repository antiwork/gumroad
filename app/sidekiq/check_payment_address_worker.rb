# frozen_string_literal: true

class CheckPaymentAddressWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if user.nil? || user.payment_address.blank?

    blocked_email = BlockedObject.find_active_object(user.payment_address)

    fraud_accounts = User.where(
      payment_address: user.payment_address,
      user_risk_state: "suspended_for_fraud"
    )

    if (fraud_accounts.exists? || blocked_email.present?) && user.can_flag_for_fraud?
      user.flag_for_fraud!(author_name: "CheckPaymentAddress")
      return
    end

    return unless user.not_reviewed? || user.compliant?

    tos_accounts = User.where(
      payment_address: user.payment_address,
      user_risk_state: "suspended_for_tos_violation"
    )

    if tos_accounts.exists?
      related_account = tos_accounts.first
      user.put_on_probation!(
        author_name: "CheckPaymentAddress",
        content: "Probated for having the same payout address as a previously suspended account (User##{related_account.id})"
      )
    end
  end
end
