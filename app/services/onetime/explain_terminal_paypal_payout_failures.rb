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

    # Deliberately not "all time". Anything older is long past being actionable for the seller, and
    # the rejection almost certainly no longer reflects the state of their PayPal account.
    LOOKBACK = 300.days

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

        if already_explained?(user)
          skipped += 1
          next
        end

        if dry_run
          puts "[dry run] would explain #{payment.failure_reason} to User #{user.id}"
        else
          user.add_payout_note(content: note_content(payment), seller_visible: true)
          puts "Explained #{payment.failure_reason} to User #{user.id}"
        end
        noted += 1
      end

      puts "Done. #{noted} sellers explained, #{skipped} skipped."
      { noted:, skipped: }
    end

    private
      # The most recent terminal failure per seller — that is the one whose reason and date describe
      # why their payouts are stopped today.
      def terminal_failures_by_user(batch_size:)
        latest = {}

        Payment.where(processor: PayoutProcessorType::PAYPAL, state: Payment::FAILED,
                      failure_reason: Payment::FailureReason::TERMINAL_PAYPAL_FAILURE_REASONS)
               .where("created_at > ?", LOOKBACK.ago)
               .in_batches(of: batch_size) do |batch|
          ReplicaLagWatcher.watch
          batch.each do |payment|
            current = latest[payment.user_id]
            latest[payment.user_id] = payment if current.nil? || payment.created_at > current.created_at
          end
        end

        latest
      end

      def still_blocked?(user)
        payout_email = user.paypal_payout_email
        return false if payout_email.blank?

        PaypalPayoutProcessor.terminal_failure_for_payout_email?(user, payout_email)
      end

      # Re-running the task must not stack duplicate notes on the same account. The note names
      # PayPal and the restriction, which no other payout note does, so matching on the reason
      # sentence is enough to recognise one we already wrote.
      def already_explained?(user)
        reasons = Payment::FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_REASONS.values
        user.comments.with_type_payout_note.any? do |comment|
          reasons.any? { |reason| comment.content.to_s.include?(reason) }
        end
      end

      def note_content(payment)
        "Your payout on #{payment.created_at.to_fs(:formatted_date_full_month)} could not be sent because " \
          "#{Payment::FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_REASONS.fetch(payment.failure_reason)}. " \
          "#{payment.terminal_paypal_failure_seller_solution}"
      end
  end
end
