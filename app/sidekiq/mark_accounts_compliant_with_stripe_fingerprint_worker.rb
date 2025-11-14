# frozen_string_literal: true

class MarkAccountsCompliantWithStripeFingerprintWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id)
    compliant_user = User.find(user_id)
    stripe_fingerprint = compliant_user.active_bank_account.stripe_fingerprint

    return if stripe_fingerprint.blank?

    User
      .without_user_risk_state(:compliant)
      .where.not(id: compliant_user.id)
      .joins(:bank_accounts)
      .merge(BankAccount.where(stripe_fingerprint:).alive)
      .find_each do
        _1.mark_compliant(
          author_name: User::Risk::ENABLE_SELLER_ACCOUNTS_AUTHOR_NAME,
          content: "Marked compliant automatically on #{Time.current.to_fs(:formatted_date_full_month)} as Stripe fingerprint #{stripe_fingerprint} is now unblocked (from User##{compliant_user.id})",
          skip_transition: :enable_sellers_other_accounts
        )
      end
  end
end
