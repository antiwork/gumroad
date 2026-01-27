# frozen_string_literal: true

class MarkAccountsCompliantWithStripeFingerprintWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id)
    compliant_user = User.with_user_risk_state(:compliant).find(user_id)
    stripe_fingerprints_to_unblock_by_seller = BankAccount.where(stripe_fingerprint: compliant_user.bank_accounts.where.not(stripe_fingerprint: [nil, ""]).select(:stripe_fingerprint))
                                                          .joins(:user)
                                                          .merge(User.without_user_risk_state(:compliant).where.not(id: compliant_user.id))
                                                          .group(:user_id).pluck(:user_id, Arel.sql("GROUP_CONCAT(DISTINCT stripe_fingerprint)"))
                                                          .to_h.transform_values { |fps| (fps || "").split(",") }
                                                          .compact_blank

    return if stripe_fingerprints_to_unblock_by_seller.blank?

    User.where(id: stripe_fingerprints_to_unblock_by_seller.keys).find_each do |user|
      user.mark_compliant(
        author_name: User::Risk::ENABLE_SELLER_ACCOUNTS_AUTHOR_NAME,
        content: "Marked compliant automatically on #{Time.current.to_fs(:formatted_date_full_month)} as #{self.class.format_stripe_fingerprints(stripe_fingerprints_to_unblock_by_seller[user.id] || [])} now unblocked (from User##{compliant_user.id})",
        skip_transition_callback: :enable_sellers_other_accounts
      )
    end
  end

  def self.format_stripe_fingerprints(fingerprints)
    fingerprints.size == 1 ? "Stripe fingerprint #{fingerprints.first}" : "Stripe fingerprints #{fingerprints.to_sentence}"
  end
end
