# frozen_string_literal: true

class FlagForFraudStripeFingerprintWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  FLAG_FOR_FRAUD_STRIPE_FINGERPRINT_AUTHOR_NAME = "FlagForFraudStripeFingerprintWorker"

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if user.blank?

    stripe_fingerprints_to_check = user.bank_accounts.distinct(:stripe_fingerprint).pluck(:stripe_fingerprint).compact_blank
    return if !user.can_flag_for_fraud? || stripe_fingerprints_to_check.blank?

    # Ordered by updated_at descending so that support can backtrace accounts by most recent activity in reverse chronological order
    banned_accounts_with_same_stripe_fingerprint = User.suspended
                                                       .joins(:bank_accounts)
                                                       .merge(BankAccount.where(stripe_fingerprint: stripe_fingerprints_to_check))
                                                       .distinct
                                                       .order("users.updated_at" => :desc)

    blocked_stripe_fingerprints_on_purchase = BlockedObject.find_active_objects(stripe_fingerprints_to_check)

    suspended_for_fraud_uids = banned_accounts_with_same_stripe_fingerprint.with_user_risk_state(:suspended_for_fraud).pluck(:external_id)
    suspended_for_tos_violation_uids = banned_accounts_with_same_stripe_fingerprint.with_user_risk_state(:suspended_for_tos_violation).pluck(:external_id)
    has_fraudulent_activity_on_other_accounts = suspended_for_fraud_uids.present? || blocked_stripe_fingerprints_on_purchase.present?

    if suspended_for_tos_violation_uids.present? && (user.compliant? || user.not_reviewed?) && !has_fraudulent_activity_on_other_accounts
      matched_fingerprints = self.class.fetch_matched_fingerprints(stripe_fingerprints_to_check, suspended_for_tos_violation_uids)
      user.put_on_probation!(
        author_name: FLAG_FOR_FRAUD_STRIPE_FINGERPRINT_AUTHOR_NAME,
        content: "Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of #{self.class.format_stripe_fingerprints(matched_fingerprints)} (from suspended for TOS violation #{self.class.pluralize_user_label(suspended_for_tos_violation_uids.count)} #{self.class.format_uids(suspended_for_tos_violation_uids)})"
      )
    elsif has_fraudulent_activity_on_other_accounts
      if suspended_for_fraud_uids.present?
        matched_fingerprints = self.class.fetch_matched_fingerprints(stripe_fingerprints_to_check, suspended_for_fraud_uids)
        source = "from suspended for fraud #{self.class.pluralize_user_label(suspended_for_fraud_uids.count)} #{self.class.format_uids(suspended_for_fraud_uids)}"
      else
        matched_fingerprints = blocked_stripe_fingerprints_on_purchase.pluck(:object_value).compact_blank
        source = "from a fraudulent purchase"
      end
      user.flag_for_fraud!(
        author_name: FLAG_FOR_FRAUD_STRIPE_FINGERPRINT_AUTHOR_NAME,
        content: "Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of #{self.class.format_stripe_fingerprints(matched_fingerprints)} (#{source})"
      )
    end
  end

  def self.format_uids(uids)
    uids.map { "##{_1}" }.to_sentence
  end

  def self.pluralize_user_label(count)
    count == 1 ? "User" : "Users"
  end

  def self.format_stripe_fingerprints(fingerprints)
    if fingerprints.size == 1
      "Stripe fingerprint #{fingerprints.first}"
    else
      "Stripe fingerprints #{fingerprints.sort.to_sentence}"
    end
  end

  def self.fetch_matched_fingerprints(stripe_fingerprints_to_check, banned_external_ids)
    BankAccount.where(stripe_fingerprint: stripe_fingerprints_to_check).joins(:user).where(users: { external_id: banned_external_ids }).order("bank_accounts.stripe_fingerprint").distinct.pluck(:stripe_fingerprint).compact_blank
  end
end
