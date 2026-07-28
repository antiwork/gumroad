# frozen_string_literal: true

class RetryStripeRejectedPayoutSetupForSellerJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed

  # Every note this job writes is an internal breadcrumb: it explains to support (and to the
  # job's own later runs) what the automated retry loop did. All of them talk about the seller
  # in the third person, so they are recorded with seller_visible: false and never appear in
  # the banner on the seller's Payouts page. Anything the SELLER needs to know is sent as an
  # email instead (see notify_bank_rejection! / notify_retries_exhausted!).
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
  BANK_ACCOUNT_BLOCKED_NOTE = "Automated Stripe payout-setup retry stopped: the external account is on Stripe's " \
                              "block list, so re-sending the same saved details can never succeed. The seller has " \
                              "been emailed and has to add a different bank account."
  ABANDONED_REASON_BANK_ACCOUNT_BLOCKED = "bank_account_blocked_by_stripe"
  BANK_TERMINAL_REJECTION_NOTE = "Automated Stripe payout-setup retry stopped: Stripe refused the bank account " \
                                 "itself (previous payments or payouts failed, or the bank cannot receive payouts), " \
                                 "so re-sending the same saved details can never succeed. The seller has been " \
                                 "emailed and has to nominate a different bank account."
  ABANDONED_REASON_BANK_TERMINAL_REJECTION = "bank_details_terminally_rejected"
  # How long one run's "I am sending this email right now" claim holds off other runs. Long
  # enough that two overlapping runs cannot both send, short enough that a run killed mid-send
  # does not delay the seller past the next weekly pass.
  NOTIFICATION_CLAIM_TTL = 1.hour

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
    # branch suffix the country's format doesn't allow); a terminal rejection means it refused
    # the account itself (payouts to it failed before, or the bank cannot receive payouts); a
    # block means Stripe refuses this one external account by name (gumroad-private#1476).
    # Either way remediation would re-send the identical saved value, so every weekly attempt is
    # guaranteed to fail the same way and the seller ends up waiting out the whole retry window
    # for nothing. Stop the loop immediately instead — but only after making sure the seller has
    # actually been told, because a note recorded during account creation (which re-raises rather
    # than emailing) or before this field existed means nobody has told them what to change.
    # Abandoning silently in that case would strand them worse than the retry loop did.
    #
    # Narrowest claim first: a block names one account, terminal covers the account, format only
    # covers how it was typed. Asking format first would send a seller whose account can never be
    # accepted back to re-type digits that were already correct.
    if bank_note?(note)
      if StripeMerchantAccountManager.bank_account_blocked_note?(note)
        abandon_unfixable_bank_notes!(
          user,
          matcher: StripeMerchantAccountManager.method(:bank_account_blocked_note?),
          rejection_kind: StripeMerchantAccountManager::BANK_REJECTION_KIND_BLOCKED,
          reason: ABANDONED_REASON_BANK_ACCOUNT_BLOCKED,
          note_content: BANK_ACCOUNT_BLOCKED_NOTE
        )
        return
      end

      if StripeMerchantAccountManager.bank_details_terminal_rejection_note?(note)
        abandon_unfixable_bank_notes!(
          user,
          matcher: StripeMerchantAccountManager.method(:bank_details_terminal_rejection_note?),
          rejection_kind: StripeMerchantAccountManager::BANK_REJECTION_KIND_TERMINAL,
          reason: ABANDONED_REASON_BANK_TERMINAL_REJECTION,
          note_content: BANK_TERMINAL_REJECTION_NOTE
        )
        return
      end

      if StripeMerchantAccountManager.bank_details_format_rejection_note?(note)
        abandon_unfixable_bank_notes!(
          user,
          matcher: StripeMerchantAccountManager.method(:bank_details_format_rejection_note?),
          rejection_kind: StripeMerchantAccountManager::BANK_REJECTION_KIND_FORMAT,
          reason: ABANDONED_REASON_BANK_FORMAT_REJECTION,
          note_content: BANK_FORMAT_REJECTION_NOTE
        )
        return
      end
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
        user.add_payout_note(content: note_content, seller_visible: false)
      end
    end

    # Abandons EVERY outstanding bank note of one unfixable-by-retry class in a single pass, with
    # a single audit note. A failing account creation retries (CreateStripeMerchantAccountWorker
    # has retry: 5) and records a note each time, so a seller can accumulate several identical
    # notes; doing them one per weekly run would append a duplicate audit note on each pass.
    #
    # `matcher` selects the notes of this class, and `rejection_kind` is what the seller's email
    # branches on — the two must describe the same failure, since abandonment is terminal and that
    # email is the seller's only instruction for getting paid. Only notes of the SAME class are
    # swept, so a seller holding more than one kind gets one abandonment and one email per kind
    # rather than a single note that misdescribes half of them.
    def abandon_unfixable_bank_notes!(user, matcher:, rejection_kind:, reason:, note_content:)
      notes = payout_setup_failure_notes(user).select do |candidate|
        candidate.json_data["abandoned_at"].blank? &&
          bank_note?(candidate) &&
          matcher.call(candidate)
      end
      return if notes.empty?

      already_notified = notes.any? { |candidate| StripeMerchantAccountManager.bank_sync_note_seller_notified?(candidate) }
      note_to_notify = already_notified ? nil : notes.first
      if note_to_notify
        # Abandonment is terminal and this email is the seller's only instruction on what to
        # change, so do not abandon until the email is actually on the queue. A false return means
        # another run holds the send claim; leave the notes outstanding and let whichever run does
        # the sending finish the job.
        return unless notify_bank_rejection!(user, note_to_notify, rejection_kind)
      end

      # The abandonment and the payout note explaining it are one unit (see abandon_stale_notes!),
      # but the "we told them" marker deliberately is NOT part of it — send_once! already
      # committed it once the email was on the queue. If it lived in here, a failure while
      # writing the audit note would roll the marker back too, and the next weekly pass would
      # re-select these notes and email the seller the same message all over again, once per
      # pass, for as long as the write failed.
      ActiveRecord::Base.transaction do
        notes.each do |candidate|
          candidate.json_data["abandoned_at"] = Time.current.iso8601
          candidate.json_data["abandoned_reason"] = reason
          candidate.save!
        end
        user.add_payout_note(content: note_content, seller_visible: false)
      end
    end

    def notify_bank_rejection!(user, note, rejection_kind)
      _code, message = StripeMerchantAccountManager.bank_sync_note_error_details(note)
      send_once!(note, marker: "seller_notified") do
        ContactingCreatorMailer.invalid_bank_account(user.id, rejection_kind, message).deliver_later(queue: "critical")
      end
    end

    # Sends a one-time email about a payout note and records that it went out, without ever
    # letting a crash decide that the seller has been told when they have not.
    #
    # Two separate fields do the bookkeeping:
    #
    #   <marker>_claimed_at — "a run is sending this right now". Written and committed BEFORE
    #                         the email is enqueued, so a second run overlapping the first does
    #                         not send a duplicate.
    #   <marker>            — "the email really was handed to the mail queue". Written only
    #                         AFTER the enqueue returns.
    #
    # Only the second field silences later passes for good. A claim silences them for
    # NOTIFICATION_CLAIM_TTL and no longer: if the process is killed outright between the claim
    # commit and the enqueue, nothing runs to release the claim, but it expires and the next
    # weekly pass sends for real. That is the difference that matters — a hard kill costs a
    # delay, not a seller who is abandoned without ever being told to fix their bank details.
    # (The abandonment happens after the enqueue in the same run, so a kill in that window also
    # leaves the note outstanding for that later pass to find.)
    #
    # The price is the usual at-least-once residue in the other direction: if the enqueue
    # succeeds and the process dies before the confirmation commits, the expired claim lets a
    # later pass send a second copy. A seller reading the same "correct your bank code" notice
    # twice is a far smaller harm than one who never reads it at all.
    #
    # Neither field is part of the abandonment transaction that follows. Abandonment is
    # terminal, so a rolled-back abandonment leaves the note outstanding and every later weekly
    # pass arrives here again; if the confirmation rolled back with it, each of those passes
    # would email the seller the same notice over again.
    def send_once!(note, marker:)
      return true if note.json_data[marker] == true
      # Another run is mid-send. It will finish (or its claim will expire and a later pass will
      # retry), but as far as THIS run knows the seller has not been told yet, so it must not
      # go on to abandon the note.
      return false if notification_claim_active?(note, marker)

      claim_key = "#{marker}_claimed_at"
      note.json_data[claim_key] = Time.current.iso8601
      note.save!

      begin
        yield
      rescue
        # Best effort: if this release fails too, the claim still expires on its own, so the
        # next pass re-sends. Log it either way — an unreleased claim means a seller waits a
        # week longer than they should to hear anything.
        begin
          note.json_data.delete(claim_key)
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

      begin
        note.json_data[marker] = true
        note.json_data.delete(claim_key)
        note.save!
      rescue => confirm_error
        # The email is already queued, so the seller will hear from us and this run should carry
        # on to the abandonment. Only the record of having sent it is missing; the live claim
        # holds off duplicates until it expires.
        Rails.logger.error(
          "RetryStripeRejectedPayoutSetupForSellerJob sent the #{marker} email for payout note " \
          "#{note.id} but could not record it: #{confirm_error.class}: #{confirm_error.message}"
        )
        ErrorNotifier.notify(confirm_error)
      end

      # The email is on the queue either way, so the seller will hear from us.
      true
    end

    # A claim only holds off other runs while it is fresh. An expired one means the run that
    # made it never got as far as confirming the send, so the email has to be attempted again.
    def notification_claim_active?(note, marker)
      claimed_at = note.json_data["#{marker}_claimed_at"]
      return false if claimed_at.blank?

      Time.zone.parse(claimed_at.to_s).then { |time| time.present? && time > NOTIFICATION_CLAIM_TTL.ago }
    rescue ArgumentError
      # An unparseable timestamp is not a claim anyone can rely on; treat it as expired so the
      # seller still gets their email.
      false
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
      user.add_payout_note(content: RESOLVED_NOTE, seller_visible: false)
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
      # the retries stopped. See send_once! for how the send is claimed and recorded, and why
      # neither field participates in the abandonment transaction.
      # A false return means another run is mid-send; it will do the abandonment itself, and
      # abandoning here would strand the seller if that run never got the email out.
      return unless notify_retries_exhausted!(user, note)

      # Same reasoning as abandon_stale_notes!: the terminal state and its explanation are one
      # unit, so support never sees a dead note with no record of why the retries stopped.
      ActiveRecord::Base.transaction do
        note.json_data["abandoned_at"] = Time.current.iso8601
        note.save!
        user.add_payout_note(content: GAVE_UP_NOTE, seller_visible: false)
      end
    end

    def notify_retries_exhausted!(user, note)
      marker_type = bank_note?(note) ? "bank" : "postal"
      send_once!(note, marker: "exhausted_notified") do
        ContactingCreatorMailer.payout_setup_retry_exhausted(user.id, marker_type).deliver_later(queue: "critical")
      end
    end
end
