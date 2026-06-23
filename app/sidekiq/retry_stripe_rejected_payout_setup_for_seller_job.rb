# frozen_string_literal: true

class RetryStripeRejectedPayoutSetupForSellerJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed

  RESOLVED_NOTE = "Stripe accepted the previously rejected postal code / bank account on automated retry."
  GAVE_UP_NOTE = "Automated retries to fix the rejected postal code / bank account were exhausted. " \
                 "Manual follow-up is needed."
  SWITCHED_OFF_STRIPE_NOTE = "Automated Stripe payout-setup retry stopped: the seller moved to a non-Stripe payout method."
  ABANDONED_REASON_SWITCHED_OFF_STRIPE = "payout_method_switched_off_stripe"
  CONNECTED_STRIPE_NOTE = "Automated Stripe payout-setup retry stopped: the seller connected their own Stripe account."
  ABANDONED_REASON_CONNECTED_STRIPE = "payout_method_switched_to_connected_stripe"

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if user.nil? || user.suspended?

    if user.has_stripe_account_connected?
      abandon_stale_notes!(user, reason: ABANDONED_REASON_CONNECTED_STRIPE, note_content: CONNECTED_STRIPE_NOTE)
      return
    end

    if user.current_payout_processor == PayoutProcessorType::PAYPAL
      abandon_stale_notes!(user, reason: ABANDONED_REASON_SWITCHED_OFF_STRIPE, note_content: SWITCHED_OFF_STRIPE_NOTE)
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

    def abandon_stale_notes!(user, reason:, note_content:)
      notes = payout_setup_failure_notes(user).select { |note| note.json_data["abandoned_at"].blank? }
      return if notes.empty?

      notes.each do |note|
        note.json_data["abandoned_at"] = Time.current.iso8601
        note.json_data["abandoned_reason"] = reason
        note.save!
      end
      user.add_payout_note(content: note_content)
    end

    def attempt_remediation(user, note)
      passphrase = GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")

      if user.stripe_account.present?
        if bank_note?(note)
          result = StripeMerchantAccountManager.update_bank_account(user, passphrase:, notify: false)
          [:synced, :noop_metadata_match].include?(result)
        else
          return false if user.alive_user_compliance_info.nil?

          # force_address_resync re-sends the address even when the compliance info is otherwise
          # unchanged, so Stripe actually re-validates the rejected postal code. Without it the postal
          # code is diffed out, the update quietly succeeds, and the note is cleared without a re-check.
          StripeMerchantAccountManager.handle_new_user_compliance_info(
            user.alive_user_compliance_info, notify: false, force_address_resync: true
          )
          true
        end
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
      marker_type = bank_note?(note) ? "bank" : "postal"
      ContactingCreatorMailer.payout_setup_retry_exhausted(user.id, marker_type).deliver_later(queue: "critical")
    end
end
