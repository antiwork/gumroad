# frozen_string_literal: true

# Re-sends an account-critical email whose previous delivery failed with a
# transient SMTP error (see HandleEmailEventInfo::ForSignupConfirmationEmail
# for how these get scheduled, and gumroad-private#1210 for why).
#
# For the retry to actually leave the building, the address must first be
# removed from SendGrid's bounce/block suppression lists — otherwise SendGrid
# drops the re-send before it's attempted, which is exactly the silent
# failure mode we're fixing. Spam-report and global-unsubscribe lists are
# consent surfaces and are never touched.
#
# If the retry fails again, the provider posts a fresh failure event and the
# webhook handler schedules the next attempt with a longer backoff, up to
# TransientEmailFailureRetry::MAX_ATTEMPTS.
class RetryTransientEmailFailureJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform(transient_email_failure_retry_id)
    retry_record = TransientEmailFailureRetry.find_by(id: transient_email_failure_retry_id)
    return if retry_record.nil?

    case retry_record.mail_kind
    when TransientEmailFailureRetry::SIGNUP_CONFIRMATION
      retry_signup_confirmation(retry_record)
    when TransientEmailFailureRetry::RECEIPT
      retry_receipt(retry_record)
    end
  end

  private
    def retry_signup_confirmation(retry_record)
      # The confirmation email may target either the account email (initial
      # signup) or a pending new address (email change re-confirmation).
      user = User.alive.where("email = ? OR unconfirmed_email = ?", retry_record.email, retry_record.email).last
      if user.nil? || (user.confirmed? && user.unconfirmed_email.blank?)
        # Nothing to re-send: the user confirmed in the meantime (or the
        # account is gone). Clear the in-flight flag so a future failure for
        # this address can schedule retries again.
        retry_record.update!(retry_in_flight: false)
        log("skipping resend for #{retry_record.email}: no unconfirmed user found")
        return
      end

      return unless claim_attempt(retry_record)

      with_claim_restore(retry_record) do
        # Unsuppress before re-sending, or SendGrid silently drops the send.
        # Only the deliverability lists — never spam_reports or unsubscribes.
        EmailSuppressionManager.new(retry_record.email).remove_from_lists([:bounces, :blocks])

        user.send_confirmation_instructions
      end

      log("re-sent signup confirmation to #{retry_record.email} (attempt #{retry_record.attempts}/#{TransientEmailFailureRetry::MAX_ATTEMPTS}, last failure: #{retry_record.last_reason.inspect})")
    end

    def retry_receipt(retry_record)
      # Several distinct receipts can fail for one address while a single
      # retry is pending (two purchases in quick succession to a
      # temporarily-unreachable mailbox), so the row carries a LIST of
      # pending targets — each a standalone purchase or a combined charge
      # (multiple purchases in one checkout), whichever id the failure
      # event's unique-args carried. One claimed attempt resends all of them.
      targets = Array(retry_record.pending_targets)
      resolved = targets.map { |target| [target, resolve_receipt_target(target)] }

      # A target can't be re-sent when the purchase/charge is gone, or when
      # the buyer's email was corrected after the failure (support does this
      # when a typo'd address bounces) — the suppressed address is no longer
      # the recipient, so resending would email the wrong (dead) address and
      # unsuppressing it buys nothing. The guard compares against the address
      # the resend would ACTUALLY deliver to (see receipt_recipient), which
      # is not always the target record's own email.
      deliverable, dead = resolved.partition do |_target, record|
        record.present? && receipt_recipient(record) == retry_record.email
      end
      dead.each do |target, record|
        reason = record.nil? ? "purchase/charge no longer exists" : "recipient is now #{receipt_recipient(record).inspect}"
        log("skipping receipt resend for #{retry_record.email} (#{target.inspect}): #{reason}")
      end

      if deliverable.empty?
        # Nothing left to send. Drop the dead targets and release the claim
        # (without counting an attempt) so a future failure for this address
        # can schedule retries again.
        remove_targets(retry_record, targets, release_claim: true)
        return
      end

      return unless claim_attempt(retry_record)

      # Tracks which receipts actually got enqueued, so a failure partway
      # through the batch (say the second enqueue raises after the first
      # succeeded) doesn't leave already-sent receipts on the pending list —
      # the restored claim makes the Sidekiq re-run process whatever is still
      # listed, and re-listing a sent receipt would deliver it twice.
      sent_targets = []
      begin
        with_claim_restore(retry_record) do
          # Unsuppress before re-sending, or SendGrid silently drops the send.
          # Only the deliverability lists — never spam_reports or unsubscribes.
          EmailSuppressionManager.new(retry_record.email).remove_from_lists([:bounces, :blocks])

          deliverable.each do |target, record|
            if record.is_a?(Charge)
              CustomerMailer.receipt(nil, record.id).deliver_later(queue: "critical")
            else
              record.resend_receipt
            end
            sent_targets << target
          end
        end
      rescue => e
        # with_claim_restore already gave the attempt back and restored the
        # in-flight claim; before re-raising for the Sidekiq re-run, drop the
        # receipts that DID get enqueued so the re-run only sends the rest.
        remove_targets(retry_record, sent_targets) if sent_targets.any?
        raise e
      end

      # Only now that the sends are enqueued do the processed targets come
      # off the list — a crash before this point restores the claim (above)
      # and the Sidekiq re-run picks the same targets up again.
      remove_targets(retry_record, targets)

      log("re-sent #{deliverable.size} receipt(s) to #{retry_record.email} (attempt #{retry_record.attempts}/#{TransientEmailFailureRetry::MAX_ATTEMPTS}, last failure: #{retry_record.last_reason.inspect})")
    end

    def resolve_receipt_target(target)
      if target["charge_id"].present?
        Charge.find_by(id: target["charge_id"])
      elsif target["purchase_id"].present?
        Purchase.find_by(id: target["purchase_id"])
      end
    end

    # The address the resend for this record would actually be delivered to.
    # This must mirror how the mailers pick their recipient, because the
    # unsuppress + skip decisions key off it:
    # * Charge target → CustomerMailer.receipt(nil, charge_id) sends to the
    #   ORDER's email (Charge::Chargeable#orderable).
    # * Preorder authorization purchase → Purchase#resend_receipt sends the
    #   preorder receipt to the authorization purchase's own email.
    # * Any other purchase → resend_receipt enqueues SendPurchaseReceiptJob →
    #   CustomerMailer.receipt(purchase_id), which resolves through
    #   find_by_purchase_or_charge!: a purchase whose receipt was originally
    #   sent at the charge level (uses_charge_receipt?) re-sends the CHARGE
    #   receipt to the order's email, not the purchase's own email.
    def receipt_recipient(record)
      return record.orderable&.email if record.is_a?(Charge)
      return record.email if record.is_preorder_authorization

      Charge::Chargeable.find_by_purchase_or_charge!(purchase: record).orderable&.email
    end

    # Removes exactly the targets this run processed, under the row lock the
    # scheduler also takes. A new failure event may have appended another
    # target concurrently — subtracting (rather than clearing the list)
    # leaves that one in place for its own scheduled retry. with_lock reloads
    # the row, so the write can't clobber a concurrently-set in-flight claim.
    def remove_targets(retry_record, targets, release_claim: false)
      retry_record.with_lock do
        retry_record.pending_targets = Array(retry_record.pending_targets) - targets
        retry_record.retry_in_flight = false if release_claim
        retry_record.save!
      end
    end

    # Records the attempt BEFORE sending, in one atomic UPDATE guarded on
    # the in-flight flag. This makes the resend at-most-once per scheduled
    # retry: if this job crashes after sending and Sidekiq re-runs it, the
    # guard matches zero rows and we don't send a duplicate. The atomic
    # increment also means concurrent runs can never lose a count.
    def claim_attempt(retry_record)
      claimed = TransientEmailFailureRetry
        .where(id: retry_record.id, retry_in_flight: true)
        .update_all(["attempts = attempts + 1, retry_in_flight = false, updated_at = ?", Time.current])
      if claimed.zero?
        log("skipping resend for #{retry_record.email}: retry already handled (no in-flight claim)")
        return false
      end
      retry_record.reload
      true
    end

    # Runs the unsuppress+resend block. On failure, the attempt was recorded
    # but nothing was sent (e.g. the SendGrid suppression API errored) —
    # un-record it (give the attempt back and restore the in-flight claim),
    # then re-raise so Sidekiq's own retry re-runs this job and the claim
    # guard in claim_attempt lets it through. Without this, the Sidekiq
    # re-run would match zero rows on the guard and exit, permanently losing
    # the attempt with no email sent.
    #
    # The rollback is a compare-and-swap keyed on the attempts value our own
    # increment produced (retry_record.attempts, reloaded by claim_attempt).
    # That value uniquely fingerprints "our increment is the latest unrevoked
    # change": any newer job that consumed a replacement claim pushed the
    # counter higher, and the counter only comes back down when that job's
    # own rollback undoes its own increment. Two races this has to survive:
    #
    # 1. A fresh provider failure event re-claims the row (sets
    #    retry_in_flight back to true, counter unchanged) between our claim
    #    and this rescue. The guard still matches — the decrement correctly
    #    un-records our failed attempt, and setting retry_in_flight = true is
    #    a no-op on the already-true flag. The newer scheduled retry (or our
    #    Sidekiq re-run, whichever wins the claim) performs the one send.
    #
    # 2. That newer scheduled retry has ALREADY consumed the replacement
    #    claim and is mid-send (counter is ours + 1, flag false). The guard
    #    matches zero rows and we deliberately do nothing — an unguarded
    #    rollback here would decrement the newer job's attempt and recreate a
    #    claim that our Sidekiq re-run could consume, sending a duplicate
    #    email. The cost of skipping is that our failed attempt stays counted
    #    (a one-off over-count in a narrow double-race window), which is the
    #    safe direction: it can only end retries one attempt early, never
    #    double-send.
    #
    # If Sidekiq's retries are exhausted with the claim restored, the claim
    # dangles until CLAIM_EXPIRY, after which the next failure event for this
    # address releases it and scheduling resumes.
    def with_claim_restore(retry_record)
      yield
    rescue => e
      TransientEmailFailureRetry
        .where(id: retry_record.id, attempts: retry_record.attempts)
        .update_all(["attempts = attempts - 1, retry_in_flight = true, updated_at = ?", Time.current])
      raise e
    end

    def log(message)
      Rails.logger.info("[TransientEmailRetry] #{message}")
    end
end
