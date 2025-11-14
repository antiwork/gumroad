# frozen_string_literal: true

class FlagForFraudStripeFingerprintWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id)
    user = User.find(user_id)

    bank_account = user.active_bank_account
    stripe_fingerprint = bank_account.stripe_fingerprint
    return if !user.can_flag_for_fraud? || stripe_fingerprint.blank?

    banned_accounts_with_same_stripe_fingerprint = User.suspended.joins(:bank_accounts).merge(BankAccount.where(stripe_fingerprint:).alive)

    blocked_stripe_fingerprint_on_purchase = BlockedObject.find_active_object(stripe_fingerprint)

    if banned_accounts_with_same_stripe_fingerprint.exists? || blocked_stripe_fingerprint_on_purchase.present?
      user.flag_for_fraud!(author_name: "FlagForFraudStripeFingerprintWorker", content: "Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{bank_account.stripe_fingerprint}")
    end
  end
end
