# frozen_string_literal: true

class ProbateAccountsWithStripeFingerprintWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id)
    suspended_user = User.with_user_risk_state(:suspended_for_tos_violation).find(user_id)
    stripe_fingerprints_to_probate = suspended_user.bank_accounts.distinct(:stripe_fingerprint).pluck(:stripe_fingerprint).compact_blank

    return if stripe_fingerprints_to_probate.blank?

    User.where.not(id: suspended_user.id).with_user_risk_state(:not_reviewed, :compliant).joins(:bank_accounts).merge(BankAccount.where(stripe_fingerprint: stripe_fingerprints_to_probate)).distinct.find_each(batch_size: 100) do |user|
      user.put_on_probation!(
        author_name: User::Risk::PROBATE_SELLERS_OTHER_ACCOUNTS_AUTHOR_NAME,
        content: "Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{stripe_fingerprints_to_probate.first} (from suspended for TOS violation User##{suspended_user.id})"
      )
    end
  end
end
