# frozen_string_literal: true

class SuspendAccountsWithStripeFingerprintWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id)
    suspended_user = User.with_user_risk_state(:suspended_for_fraud).find(user_id)
    stripe_fingerprints_by_user_to_suspend = BankAccount.where(stripe_fingerprint: suspended_user.bank_accounts.where.not(stripe_fingerprint: [nil, ""]).select(:stripe_fingerprint))
                                                        .joins(:user)
                                                        .merge(User.where.not(id: suspended_user.id).not_suspended)
                                                        .group(:user_id)
                                                        .pluck(:user_id, Arel.sql("GROUP_CONCAT(DISTINCT stripe_fingerprint)"))
                                                        .to_h.transform_values { |fps| (fps || "").split(",") }
                                                        .compact_blank

    return if stripe_fingerprints_by_user_to_suspend.blank?

    User.where(id: stripe_fingerprints_by_user_to_suspend.keys).find_each do |user|
      fingerprint_text = self.class.format_stripe_fingerprints(stripe_fingerprints_by_user_to_suspend[user.id] || [])
      user.flag_for_fraud(
        author_name: User::Risk::SUSPEND_SELLERS_OTHER_ACCOUNTS_AUTHOR_NAME,
        content: "Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of #{fingerprint_text} (from User##{suspended_user.id})"
      )
      user.suspend_for_fraud(
        author_name: User::Risk::SUSPEND_SELLERS_OTHER_ACCOUNTS_AUTHOR_NAME,
        content: "Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of #{fingerprint_text} (from User##{suspended_user.id})",
        skip_transition_callback: :suspend_sellers_other_accounts
      )
    end
  end

  def self.format_stripe_fingerprints(fingerprints)
    fingerprints.size == 1 ? "Stripe fingerprint #{fingerprints.first}" : "Stripe fingerprints #{fingerprints.to_sentence}"
  end
end
