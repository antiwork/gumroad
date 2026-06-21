# frozen_string_literal: true

class RetryStripeRejectedPayoutSetupForSellerJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed

  RESOLVED_NOTE = "Stripe accepted the previously rejected postal code / bank account on automated retry."
  GAVE_UP_NOTE = "Automated retries to fix the rejected postal code / bank account were exhausted. " \
                 "Manual follow-up is needed."
  SWITCHED_OFF_STRIPE_NOTE = "Automated Stripe payout-setup retry stopped: the seller moved to a non-Stripe payout method."
  ABANDONED_REASON_SWITCHED_OFF_STRIPE = "payout_method_switched_off_stripe"

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if user.nil? || user.suspended? || user.has_stripe_account_connected?

    if user.current_payout_processor == PayoutProcessorType::PAYPAL
      abandon_stale_notes!(user)
      return
    end

    note = oldest_outstanding_note(user)
    return if note.nil?

    if RetryStripeRejectedPayoutSetupsJob.retry_count(note) >= RetryStripeRejectedPayoutSetupsJob::MAX_RETRIES
      give_up!(user, note)
      return
    end

    remediated = attempt_remediation(user, note)
    if remediated
      resolve!(user, note)
    elsif note.reload.alive?
      record_attempt!(note)
    end
  rescue => e
    ErrorNotifier.notify(e)
  end

  private
    def payout_setup_failure_notes(user)
      user.comments
          .alive
          .with_type_payout_note
          .where(author_id: GUMROAD_ADMIN_ID)
          .where(
            "content LIKE ? OR content LIKE ?",
            "#{StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX}%",
            "#{StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX}%"
          )
    end

    def oldest_outstanding_note(user)
      payout_setup_failure_notes(user)
        .order(created_at: :asc)
        .find { |candidate| candidate.json_data["abandoned_at"].blank? }
    end

    def abandon_stale_notes!(user)
      notes = payout_setup_failure_notes(user).select { |note| note.json_data["abandoned_at"].blank? }
      return if notes.empty?

      notes.each do |note|
        note.json_data["abandoned_at"] = Time.current.iso8601
        note.json_data["abandoned_reason"] = ABANDONED_REASON_SWITCHED_OFF_STRIPE
        note.save!
      end
      user.add_payout_note(content: SWITCHED_OFF_STRIPE_NOTE)
    end

    def attempt_remediation(user, note)
      passphrase = GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")

      if bank_note?(note)
        result = StripeMerchantAccountManager.update_bank_account(user, passphrase:, notify: false)
        [:synced, :noop_metadata_match].include?(result)
      elsif user.stripe_account.present?
        return false if user.alive_user_compliance_info.nil?

        StripeMerchantAccountManager.handle_new_user_compliance_info(user.alive_user_compliance_info, notify: false)
        true
      else
        return false unless user.native_payouts_supported?
        return false if StripeMerchantAccountManager::NEW_ACCOUNT_CREATION_BLOCKED_COUNTRIES
          .include?(user.alive_user_compliance_info&.legal_entity_country_code)

        StripeMerchantAccountManager.create_account(user, passphrase:, notify: false)
        true
      end
    rescue => e
      Rails.logger.error("RetryStripeRejectedPayoutSetupForSellerJob remediation failed for user #{user.id}: #{e.class}: #{e.message}")
      false
    end

    def bank_note?(note)
      note.content.start_with?(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX)
    end

    def resolve!(user, note)
      note.mark_deleted! if note.reload.alive?
      user.add_payout_note(content: RESOLVED_NOTE)
    end

    def record_attempt!(note)
      note.json_data["retry_count"] = RetryStripeRejectedPayoutSetupsJob.retry_count(note) + 1
      note.json_data["last_retried_at"] = Time.current.iso8601
      note.save!
    end

    def give_up!(user, note)
      note.json_data["abandoned_at"] = Time.current.iso8601
      note.save!
      user.add_payout_note(content: GAVE_UP_NOTE)
      ContactingCreatorMailer.payouts_may_be_blocked(user.id).deliver_later(queue: "critical")
    end
end
