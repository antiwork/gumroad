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

      # Marking a note abandoned is terminal: every later run skips abandoned notes. So the
      # abandonment and the payout note that explains WHY the retries stopped have to land
      # together, otherwise a failure between them leaves support looking at a dead record
      # with no explanation and no way to ever get one.
      ActiveRecord::Base.transaction do
        notes.each do |note|
          note.json_data["abandoned_at"] = Time.current.iso8601
          note.json_data["abandoned_reason"] = reason
          note.save!
        end
        user.add_payout_note(content: note_content)
      end
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

      already_notified = notes.any? { |candidate| StripeMerchantAccountManager.bank_sync_note_seller_notified?(candidate) }
      note_to_notify = already_notified ? nil : notes.first
      notify_format_rejection!(user, note_to_notify) if note_to_notify

      # The abandonment and the payout note explaining it are one unit (see abandon_stale_notes!),
      # but the "we told them" marker deliberately is NOT part of it — send_once! already
      # committed it. If it lived in here, a failure while writing the audit note would roll the
      # marker back too, and the next weekly pass would re-select these notes and email the
      # seller the same message all over again, once per pass, for as long as the write failed.
      ActiveRecord::Base.transaction do
        notes.each do |candidate|
          candidate.json_data["abandoned_at"] = Time.current.iso8601
          candidate.json_data["abandoned_reason"] = ABANDONED_REASON_BANK_FORMAT_REJECTION
          candidate.save!
        end
        user.add_payout_note(content: BANK_FORMAT_REJECTION_NOTE)
      end
    end

    def notify_format_rejection!(user, note)
      _code, message = StripeMerchantAccountManager.bank_sync_note_error_details(note)
      send_once!(note, marker: "seller_notified") do
        ContactingCreatorMailer.invalid_bank_account(
          user.id,
          StripeMerchantAccountManager::BANK_REJECTION_KIND_FORMAT,
          message
        ).deliver_later(queue: "critical")
      end
    end

    # Sends a one-time email about a payout note and records that it went out, in the one order
    # that cannot both duplicate the email and lose it.
    #
    # The marker is committed BEFORE the email is enqueued (the "claim"), so no later pass can
    # send a second copy just because a write after the enqueue failed — that write no longer
    # exists. If the enqueue itself fails, the claim is released again, so the note is still
    # eligible and the next pass re-sends. Losing the email therefore takes two failures in a
    # row (the enqueue AND the release), where either ordering of "send then mark" or "mark
    # inside the terminal transaction" only takes one.
    #
    # The marker is also NOT part of the abandonment transaction that follows. Abandonment is
    # terminal, so a rolled-back abandonment leaves the note outstanding and every later weekly
    # pass arrives here again; if the marker rolled back with it, each of those passes would
    # email the seller the same notice over again.
    #
    # What is left is the ordinary at-least-once residue: if the process is killed outright
    # between the claim commit and the enqueue, nothing runs to release the claim and the seller
    # is not told. That window is a hard kill rather than a raised exception, and it is the
    # narrowest of the three available failure modes — an exhaustive fix needs a transactional
    # outbox, which is a bigger change than this job.
    def send_once!(note, marker:)
      return if note.json_data[marker] == true

      note.json_data[marker] = true
      note.save!

      begin
        yield
      rescue
        # Best effort: if this release fails too, the claim stands and the seller is not told.
        # Log it loudly — that combination is the only way this path can go silent.
        begin
          note.json_data.delete(marker)
          note.save!
        rescue => release_error
          Rails.logger.error(
            "RetryStripeRejectedPayoutSetupForSellerJob could not release the #{marker} claim on " \
            "payout note #{note.id}: #{release_error.class}: #{release_error.message}"
          )
          ErrorNotifier.notify(release_error)
        end
        raise
      end
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
      # Tell the seller before the abandonment below, and outside its transaction. Abandonment is
      # terminal — once abandoned_at commits, no later run looks at this note again, and this is
      # the only place the exhausted-retries email is sent — so an enqueue downstream of that
      # commit could fail, be swallowed by the job's rescue, and leave the seller never knowing
      # the retries stopped. See send_once! for why the marker is claimed before the enqueue and
      # why it deliberately does not participate in the abandonment transaction.
      notify_retries_exhausted!(user, note)

      # Same reasoning as abandon_stale_notes!: the terminal state and its explanation are one
      # unit, so support never sees a dead note with no record of why the retries stopped.
      ActiveRecord::Base.transaction do
        note.json_data["abandoned_at"] = Time.current.iso8601
        note.save!
        user.add_payout_note(content: GAVE_UP_NOTE)
      end
    end

    def notify_retries_exhausted!(user, note)
      marker_type = bank_note?(note) ? "bank" : "postal"
      send_once!(note, marker: "exhausted_notified") do
        ContactingCreatorMailer.payout_setup_retry_exhausted(user.id, marker_type).deliver_later(queue: "critical")
      end
    end
end
