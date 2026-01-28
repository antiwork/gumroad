# frozen_string_literal: true

class CheckStripeFingerprintWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default, lock: :until_executed

  def perform(user_id, stripe_fingerprint)
    if stripe_fingerprint.blank?
      Rails.logger.info("CheckStripeFingerprintWorker: Stripe fingerprint blank for user #{user_id}, skipping")
      return
    end

    user = User.find_by(id: user_id)

    if user.blank?
      Rails.logger.info("CheckStripeFingerprintWorker: User #{user_id} not found, skipping")
      return
    end

    if !user.can_flag_for_fraud?
      Rails.logger.info("CheckStripeFingerprintWorker: User #{user_id} cannot be flagged (state: #{user.user_risk_state}), skipping")
      return
    end

    suspended_users_with_same_fingerprint = BankAccount
      .joins(:user)
      .where(stripe_fingerprint: stripe_fingerprint)
      .where(users: { user_risk_state: %w[suspended_for_tos_violation suspended_for_fraud] })
      .where.not(user_id: user_id)

    blocked_fingerprint = BlockedObject.find_active_object(stripe_fingerprint)

    if suspended_users_with_same_fingerprint.exists? || blocked_fingerprint.present?
      user.flag_for_fraud!(author_name: "CheckStripeFingerprint")
    end
  end
end
