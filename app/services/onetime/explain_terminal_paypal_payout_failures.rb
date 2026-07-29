# frozen_string_literal: true

# Explain the stopped payouts to the sellers who were already stuck when we shipped the fix.
#
# PayPal rejections 3148 and 14159 describe the receiving PayPal account, so re-sending the same
# payout can never succeed. The payout pipeline used to retry them every week anyway — sellers here
# have a median of 22 identical failures each, worst case 37 — and told the seller nothing beyond a
# generic "payouts were paused by the system" note (gumroad-private#1478).
#
# The fix stops the retries and writes a seller-visible note explaining why, but both only happen on
# a new payout failure. For sellers who were already stuck, the block means there is no next failure,
# so nothing would ever fire and they would keep seeing the same uninformative note they have been
# staring at for months. This walks the existing population once and writes the note they should
# have had all along.
#
# Notes only: the one-time email to these sellers is tracked separately so its copy can be reviewed
# before anything sends.
module Onetime
  class ExplainTerminalPaypalPayoutFailures
    BATCH_SIZE = 500

    def self.process(batch_size: BATCH_SIZE, dry_run: false)
      new.process(batch_size:, dry_run:)
    end

    def process(batch_size: BATCH_SIZE, dry_run: false)
      noted = 0
      skipped = 0

      terminal_failures_by_user(batch_size:).each do |user_id, payment|
        user = User.find_by(id: user_id)
        if user.nil?
          skipped += 1
          next
        end

        # Only speak to sellers the block actually applies to right now. Someone who has since moved
        # to a bank account, changed PayPal address, or been paid out is no longer stuck, and telling
        # them their payouts have stopped would be false.
        unless still_blocked?(user)
          skipped += 1
          next
        end

        # Quote the rejection the seller is actually stuck on, not merely their newest one.
        payment = latest_terminal_failure_for_current_address(user) || payment

        if already_explained?(user, payment)
          skipped += 1
          next
        end

        if dry_run
          puts "[dry run] would explain #{payment.failure_reason} to User #{user.id}"
        else
          user.add_payout_note(content: payment.terminal_paypal_failure_seller_note, seller_visible: true)
          puts "Explained #{payment.failure_reason} to User #{user.id}"
        end
        noted += 1
      end

      puts "Done. #{noted} sellers explained, #{skipped} skipped."
      { noted:, skipped: }
    end

    private
      # One terminal failure per seller, to enumerate the population. No date bound on purpose: the
      # live block (PaypalPayoutProcessor.terminal_failure_for_payout_email?) refuses a payout on a
      # terminal rejection of any age, so bounding the scan here would leave sellers blocked by the
      # live check but never told why — the same silence this task exists to end. Whether each
      # seller is still stuck is decided per seller below, against the live predicate itself.
      def terminal_failures_by_user(batch_size:)
        latest = {}

        # The wider EXPLAINED set, not the retry-blocking one: the backfill exists to end the
        # silence, and a seller whose rejection we still retry is just as unexplained as one we
        # have stopped retrying.
        Payment.where(processor: PayoutProcessorType::PAYPAL, state: Payment::FAILED,
                      failure_reason: Payment::FailureReason::EXPLAINED_PAYPAL_FAILURE_REASONS)
               .in_batches(of: batch_size) do |batch|
          ReplicaLagWatcher.watch
          batch.each do |payment|
            current = latest[payment.user_id]
            latest[payment.user_id] = payment if current.nil? || payment.created_at > current.created_at
          end
        end

        latest
      end

      # A seller can have terminal rejections against more than one PayPal address, and more than
      # one against the address they are stuck on now. Which of them the note should quote is the
      # live payout path's question, not this task's — asked there so the backfill cannot describe a
      # different blocker than the weekly run does.
      def latest_terminal_failure_for_current_address(user)
        PaypalPayoutProcessor.rejection_to_explain(user)
      end

      def still_blocked?(user)
        # A closed or suspended account is not going to be paid whatever they do, so telling them
        # "your payouts stopped, fix your PayPal account and you'll be paid on the next payout date"
        # would be false. Both are checked before the payout method is even considered
        # (Payouts.is_user_payable), so neither is stuck for the reason this note describes.
        return false if user.deleted? || user.suspended?

        # Everything else — a bank account on file, a changed PayPal address, a payout that
        # succeeded since the rejection — is asked of the live block itself rather than
        # re-implemented here, so this note can only reach sellers the code really is refusing to
        # pay. A second copy of that logic would drift, and the drift would be us telling sellers
        # something the payout pipeline no longer does.
        PaypalPayoutProcessor.terminal_failure_blocking_payouts?(
          user, reasons: Payment::FailureReason::EXPLAINED_PAYPAL_FAILURE_REASONS
        )
      end

      # Re-running the task must not stack duplicate notes on the same account. Matched against the
      # rejection about to be described — its date and its restriction — rather than against
      # "carries any terminal-PayPal explanation": a seller can already hold a note about a
      # rejection on a PayPal address they have since replaced, and that note does not explain the
      # block they are under today. Recognising it as one would leave them with the stale date and
      # possibly the wrong restriction of the two, which is the silence this task exists to end.
      def already_explained?(user, payment)
        user.comments.with_type_payout_note.any? do |comment|
          Payment::FailureReason.terminal_paypal_explanation_note_for?(comment.content, payment)
        end
      end
  end
end
