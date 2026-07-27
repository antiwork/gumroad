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
  ACCOUNT_BLOCKED_NOTE = "Automated Stripe payout-setup retry stopped: payments on the seller's Stripe account are blocked at the platform level."
  ABANDONED_REASON_ACCOUNT_BLOCKED = "stripe_account_blocked_by_platform"
  BANK_FORMAT_REJECTION_NOTE = "Automated Stripe payout-setup retry stopped: the bank code was rejected on format, " \
                               "so re-sending the same saved details can never succeed. The seller has been emailed " \
                               "and has to re-enter the code."
  ABANDONED_REASON_BANK_FORMAT_REJECTION = "bank_details_format_rejected"

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

    # A format rejection means Stripe refused the bank code as typed (wrong length, spaces, a
    # branch suffix the country's format doesn't allow). Remediation would re-send the identical
    # saved value, so every weekly attempt is guaranteed to fail the same way and the seller ends
    # up waiting out the whole retry window for nothing. Stop the loop immediately instead — but
    # only after making sure the seller has actually been told, because a note recorded during
    # account creation (which re-raises rather than emailing) or before this field existed means
    # nobody has told them their code needs correcting. Abandoning silently in that case would
    # strand them worse than the retry loop did.
    if bank_note?(note) && StripeMerchantAccountManager.bank_details_format_rejection_note?(note)
      abandon_format_rejected_notes!(user)
      return
    end

    if RetryStripeRejectedPayoutSetupsJob.retry_count(note) >= RetryStripeRejectedPayoutSetupsJob::MAX_RETRIES
      give_up!(user, note)
      return
    end

    remediated = attempt_remediation(user, note)
    if remediated == :account_blocked
      # Gumroad has blocked payments on the seller's Stripe account (platform-level risk
      # block). No amount of retrying a bank/postal-code sync can succeed until a human
      # lifts the block, so stop the automated retry loop instead of burning attempts.
      abandon_stale_notes!(user, reason: ABANDONED_REASON_ACCOUNT_BLOCKED, note_content: ACCOUNT_BLOCKED_NOTE)
    elsif remediated
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

    # Abandons EVERY outstanding format-rejected bank note in one pass, with a single audit note.
    # A failing account creation retries (CreateStripeMerchantAccountWorker has retry: 5) and
    # records a note each time, so a seller can accumulate several identical format notes; doing
    # them one per weekly run would append a duplicate audit note on each pass.
    def abandon_format_rejected_notes!(user)
      notes = payout_setup_failure_notes(user).select do |candidate|
        candidate.json_data["abandoned_at"].blank? &&
          bank_note?(candidate) &&
          StripeMerchantAccountManager.bank_details_format_rejection_note?(candidate)
      end
      return if notes.empty?

      unless notes.any? { |candidate| StripeMerchantAccountManager.bank_sync_note_seller_notified?(candidate) }
        notify_seller_of_format_rejection(user, notes.first)
      end

      ActiveRecord::Base.transaction do
        notes.each do |candidate|
          candidate.json_data["abandoned_at"] = Time.current.iso8601
          candidate.json_data["abandoned_reason"] = ABANDONED_REASON_BANK_FORMAT_REJECTION
          candidate.save!
        end
        user.add_payout_note(content: BANK_FORMAT_REJECTION_NOTE)
      end
    end

    # The email is enqueued BEFORE the note is marked as notified, and that order is deliberate.
    # "seller_notified" is not a delivery ledger; the abandonment branch reads it as "has anyone
    # told this seller their code needs correcting?", because a note recorded during account
    # creation (that path re-raises instead of emailing) has no notification behind it. Marking
    # first would mean a crash between the two writes leaves a note claiming the seller was told
    # when no email was ever enqueued — the next pass would then abandon the retries and the
    # seller hears nothing at all, which is the exact failure this job is here to prevent.
    # Enqueuing first fails the other way instead: at worst a duplicate copy of an email asking
    # them to re-enter their bank details, which is harmless and self-consistent.
    def notify_seller_of_format_rejection(user, note)
      _code, message = StripeMerchantAccountManager.bank_sync_note_error_details(note)
      ContactingCreatorMailer.invalid_bank_account(
        user.id,
        StripeMerchantAccountManager::BANK_REJECTION_KIND_FORMAT,
        message
      ).deliver_later(queue: "critical")
      StripeMerchantAccountManager.mark_bank_sync_note_seller_notified!(note)
    end

    def abandon_note!(user, note, reason:, note_content:)
      note.json_data["abandoned_at"] = Time.current.iso8601
      note.json_data["abandoned_reason"] = reason
      note.save!
      user.add_payout_note(content: note_content)
    end

    def attempt_remediation(user, note)
      passphrase = GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")

      if user.stripe_account.present?
        if bank_note?(note)
          result = StripeMerchantAccountManager.update_bank_account(user, passphrase:, notify: false)
          return :account_blocked if result == :account_blocked_by_platform
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
