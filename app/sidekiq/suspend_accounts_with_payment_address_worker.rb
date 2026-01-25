# frozen_string_literal: true

class SuspendAccountsWithPaymentAddressWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id)
    suspended_user = User.find(user_id)

    return if suspended_user.payment_address.blank?

    User.where(payment_address: suspended_user.payment_address).where.not(id: suspended_user.id).not_suspended.find_each do |user|
      if suspended_user.suspended_for_fraud?
        user.flag_for_fraud(
          author_name: "suspend_sellers_other_accounts",
          content: "Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of payment address #{suspended_user.payment_address} (from User##{suspended_user.id})"
        )
        user.suspend_for_fraud(
          author_name: "suspend_sellers_other_accounts",
          content: "Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of payment address #{suspended_user.payment_address} (from User##{suspended_user.id})",
          skip_transition_callback: :suspend_sellers_other_accounts
        )
      elsif suspended_user.suspended_for_tos_violation?
        next if user.on_probation? || user.flagged?

        user.put_on_probation!(
          author_name: "suspend_sellers_other_accounts",
          content: "Probated automatically on #{Time.current.to_fs(:formatted_date_full_month)} for having the same payout address as a previously suspended account (User##{suspended_user.id})"
        )
      end
    end
  end
end
