# frozen_string_literal: true

class CheckPaymentAddressWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user

    fraud_match = matches_fraud_suspended_account?(user)
    tos_match = matches_tos_suspended_account?(user)

    if fraud_match && user.can_flag_for_fraud?
      user.flag_for_fraud!(author_name: "CheckPaymentAddress")
    elsif tos_match && !fraud_match && !user.suspended? && !user.on_probation?
      suspended_user_ids = tos_suspended_user_ids_for(user)
      user.put_on_probation(
        author_name: "CheckPaymentAddress",
        content: "Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of payment address matching suspended for TOS violation #{suspended_user_ids.map { |uid| "User##{uid}" }.join(" and ")}"
      )
    end
  end

  private
    def matches_fraud_suspended_account?(user)
      payment_address_matches_state?(user, "suspended_for_fraud") ||
        stripe_fingerprint_matches_state?(user, "suspended_for_fraud") ||
        blocked_payment_address?(user) ||
        blocked_stripe_fingerprint?(user)
    end

    def matches_tos_suspended_account?(user)
      payment_address_matches_state?(user, "suspended_for_tos_violation") ||
        stripe_fingerprint_matches_state?(user, "suspended_for_tos_violation")
    end

    def payment_address_matches_state?(user, state)
      return false if user.payment_address.blank?

      User.where(payment_address: user.payment_address, user_risk_state: state)
        .where.not(id: user.id)
        .exists?
    end

    def stripe_fingerprint_matches_state?(user, state)
      fingerprints = user.alive_bank_accounts.where.not(stripe_fingerprint: [nil, ""]).distinct.pluck(:stripe_fingerprint)
      return false if fingerprints.empty?

      BankAccount.joins(:user)
        .where(stripe_fingerprint: fingerprints)
        .where.not(user_id: user.id)
        .where(users: { user_risk_state: state })
        .exists?
    end

    def blocked_payment_address?(user)
      return false if user.payment_address.blank?

      BlockedObject.find_active_object(user.payment_address).present?
    end

    def blocked_stripe_fingerprint?(user)
      fingerprints = user.alive_bank_accounts.where.not(stripe_fingerprint: [nil, ""]).distinct.pluck(:stripe_fingerprint)
      return false if fingerprints.empty?

      BlockedObject.find_active_objects(fingerprints).present?
    end

    def tos_suspended_user_ids_for(user)
      ids = []

      if user.payment_address.present?
        ids += User.where(payment_address: user.payment_address, user_risk_state: "suspended_for_tos_violation")
          .where.not(id: user.id)
          .pluck(:id)
      end

      fingerprints = user.alive_bank_accounts.where.not(stripe_fingerprint: [nil, ""]).distinct.pluck(:stripe_fingerprint)
      if fingerprints.any?
        ids += BankAccount.joins(:user)
          .where(stripe_fingerprint: fingerprints)
          .where.not(user_id: user.id)
          .where(users: { user_risk_state: "suspended_for_tos_violation" })
          .distinct
          .pluck(:user_id)
      end

      ids.uniq
    end
end
