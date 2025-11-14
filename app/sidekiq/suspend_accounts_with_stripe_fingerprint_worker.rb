# frozen_string_literal: true

class SuspendAccountsWithStripeFingerprintWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id)
    suspended_user = User.find(user_id)
    stripe_fingerprint = suspended_user.active_bank_account.stripe_fingerprint

    return if stripe_fingerprint.blank?

    User
    .where.not(id: suspended_user.id)
    .not_suspended
    .joins(:bank_accounts)
    .merge(BankAccount.where(stripe_fingerprint:).alive)
    .find_each do |user|
      user.flag_for_fraud(
        author_name: "suspend_sellers_other_accounts",
        content: "Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{stripe_fingerprint} (from User##{suspended_user.id})"
      )
      user.suspend_for_fraud(
        author_name: "suspend_sellers_other_accounts",
        content: "Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{stripe_fingerprint} (from User##{suspended_user.id})",
        skip_transition: :suspend_sellers_other_accounts
      )
    end
  end
end
