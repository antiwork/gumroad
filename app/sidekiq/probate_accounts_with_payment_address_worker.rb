# frozen_string_literal: true

class ProbateAccountsWithPaymentAddressWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id)
    suspended_user = User.with_user_risk_state(:suspended_for_tos_violation).find(user_id)

    return if suspended_user.payment_address.blank?

    User.where(payment_address: suspended_user.payment_address).with_user_risk_state(:not_reviewed, :compliant).where.not(id: suspended_user.id).find_each(batch_size: 100) do |user|
      user.put_on_probation!(
        author_name: "probate_sellers_other_accounts",
        content: "Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of payment address #{suspended_user.payment_address} (from suspended for TOS violation User##{suspended_user.id})"
      )
    end
  end
end
