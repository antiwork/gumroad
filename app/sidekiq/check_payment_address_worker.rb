# frozen_string_literal: true

class CheckPaymentAddressWorker
  include Sidekiq::Job

  sidekiq_options retry: 0, queue: :default

  CHECK_PAYMENT_ADDRESS_AUTHOR_NAME = "CheckPaymentAddress"

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if !user.can_flag_for_fraud? || user.payment_address.blank?

    banned_accounts_with_same_payment_address = User.where(
      payment_address: user.payment_address,
      user_risk_state: ["suspended_for_tos_violation", "suspended_for_fraud"]
    ).order(updated_at: :desc) # Ordered by updated_at descending so that support can backtrace accounts by most recent activity in reverse chronological order

    blocked_email = BlockedObject.find_active_object(user.payment_address)

    suspended_for_fraud_uids = banned_accounts_with_same_payment_address.with_user_risk_state(:suspended_for_fraud).pluck(:external_id)
    suspended_for_tos_violation_uids = banned_accounts_with_same_payment_address.with_user_risk_state(:suspended_for_tos_violation).pluck(:external_id)
    has_fraudulent_activity_on_other_accounts = suspended_for_fraud_uids.present? || blocked_email.present?

    if suspended_for_tos_violation_uids.present? && (user.compliant? || user.not_reviewed?) && !has_fraudulent_activity_on_other_accounts
      user.put_on_probation!(
        author_name: CHECK_PAYMENT_ADDRESS_AUTHOR_NAME,
        content: "Probated (payouts suspended) automatically on #{self.class.formatted_date} because of usage of payment address #{user.payment_address} (from suspended for TOS violation #{self.class.pluralize_user_label(suspended_for_tos_violation_uids.count)} #{self.class.format_uids(suspended_for_tos_violation_uids)})"
      )
    elsif has_fraudulent_activity_on_other_accounts
      source = if suspended_for_fraud_uids.present?
        "from suspended for fraud #{self.class.pluralize_user_label(suspended_for_fraud_uids.count)} #{self.class.format_uids(suspended_for_fraud_uids)}"
      else
        "from a fraudulent purchase"
      end
      user.flag_for_fraud!(
        author_name: CHECK_PAYMENT_ADDRESS_AUTHOR_NAME,
        content: "Flagged for fraud automatically on #{self.class.formatted_date} because of usage of payment address #{user.payment_address} (#{source})"
      )
    end
  end

  def self.format_uids(uids)
    uids.map { "##{_1}" }.to_sentence
  end

  def self.formatted_date
    Time.current.to_fs(:formatted_date_full_month)
  end

  def self.pluralize_user_label(count)
    count == 1 ? "User" : "Users"
  end
end
