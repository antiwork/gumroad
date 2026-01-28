# frozen_string_literal: true

class SuspendAccountsWithStripeFingerprintWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  def perform(user_id)
    suspended_user = User.find(user_id)
    fingerprints = suspended_user.bank_accounts.pluck(:stripe_fingerprint).compact.uniq

    if fingerprints.empty?
      Rails.logger.info("SuspendAccountsWithStripeFingerprintWorker: User #{user_id} has no bank accounts with fingerprints, skipping")
      return
    end

    User.joins(:bank_accounts)
        .where(bank_accounts: { stripe_fingerprint: fingerprints })
        .where.not(id: suspended_user.id)
        .distinct
        .find_each do |user|
      unless user.flag_for_fraud(
        author_name: "suspend_sellers_other_accounts",
        content: "Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of bank account fingerprint from User##{suspended_user.id}"
      )
        Rails.logger.warn("SuspendAccountsWithStripeFingerprintWorker: Failed to flag user #{user.id} (state: #{user.user_risk_state})")
        next
      end

      unless user.suspend_for_fraud(
        author_name: "suspend_sellers_other_accounts",
        content: "Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of bank account fingerprint from User##{suspended_user.id}"
      )
        Rails.logger.warn("SuspendAccountsWithStripeFingerprintWorker: Failed to suspend user #{user.id} (state: #{user.user_risk_state})")
      end
    end
  end
end
