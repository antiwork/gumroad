# frozen_string_literal: true

class SuspendAccountsWithStripeFingerprintWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  def perform(user_id)
    suspended_user = User.find(user_id)
    stripe_fingerprint = suspended_user.active_bank_account&.stripe_fingerprint

    if stripe_fingerprint.blank?
      Rails.logger.info("SuspendAccountsWithStripeFingerprintWorker: User #{user_id} has no active bank account or fingerprint, skipping")
      return
    end

    User.joins(:bank_accounts)
        .merge(BankAccount.alive)
        .where(bank_accounts: { stripe_fingerprint: stripe_fingerprint })
        .where.not(id: suspended_user.id)
        .not_suspended
        .distinct
        .find_each do |user|
      # Skip flagging if already flagged for fraud, but proceed to suspension
      unless user.flagged_for_fraud? || user.flag_for_fraud(
        author_name: "suspend_sellers_other_accounts",
        content: "Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of bank account fingerprint from User##{suspended_user.id}"
      )
        Rails.logger.warn("SuspendAccountsWithStripeFingerprintWorker: Failed to flag user #{user.id} (state: #{user.user_risk_state})")
        next
      end

      unless user.suspend_for_fraud(
        author_name: "suspend_sellers_other_accounts",
        content: "Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of bank account fingerprint from User##{suspended_user.id}",
        skip_transition_callback: :suspend_sellers_other_accounts
      )
        Rails.logger.warn("SuspendAccountsWithStripeFingerprintWorker: Failed to suspend user #{user.id} (state: #{user.user_risk_state})")
      end
    end
  end
end
