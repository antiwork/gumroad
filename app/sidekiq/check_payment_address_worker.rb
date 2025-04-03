# frozen_string_literal: true

class CheckPaymentAddressWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if !user.can_flag_for_fraud? || user.payment_address.blank?

    banned_accounts_with_same_payment_address = User.where(
      payment_address: user.payment_address,
      user_risk_state: ["suspended_for_tos_violation", "suspended_for_fraud"]
    )

    blocked_email = BlockedObject.find_active_object(user.payment_address)

    user.flag_for_fraud!(author_name: "CheckPaymentAddress") if banned_accounts_with_same_payment_address.exists? || blocked_email.present?
  end
end
