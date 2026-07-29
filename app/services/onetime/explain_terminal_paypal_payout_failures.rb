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

        if already_explained?(user)
          skipped += 1
          next
        end

        # Quote the rejection the seller is actually stuck on, not merely their newest one.
        payment = latest_terminal_failure_for_current_address(user) || payment

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
      # One terminal failure per seller, to enumerate the population. No date bound on purpose: the
      # live block (PaypalPayoutProcessor.terminal_failure_for_payout_email?) refuses a payout on a
      # terminal rejection of any age, so bounding the scan here would leave sellers blocked by the
      # live check but never told why — the same silence this task exists to end. Whether each
      # seller is still stuck is decided per seller below, against the live predicate itself.
      def terminal_failures_by_user(batch_size:)
        latest = {}

        Payment.where(processor: PayoutProcessorType::PAYPAL, state: Payment::FAILED,
                      failure_reason: Payment::FailureReason::TERMINAL_PAYPAL_FAILURE_REASONS)
               .in_batches(of: batch_size) do |batch|
          ReplicaLagWatcher.watch
          batch.each do |payment|
            current = latest[payment.user_id]
            latest[payment.user_id] = payment if current.nil? || payment.created_at > current.created_at
          end
        end

        latest
      end

      # A seller can have terminal rejections against more than one PayPal address: one against an
      # address they have since replaced, and one against the address they are stuck on now. The
      # note quotes a date and a restriction, so both have to come from a rejection against the
      # address the block is keyed on — otherwise the seller is told about a payout to an address
      # they no longer use, and possibly the wrong restriction of the two.
      def latest_terminal_failure_for_current_address(user)
        user.payments
            .where(processor: PayoutProcessorType::PAYPAL,
                   payment_address: user.paypal_payout_email,
                   state: Payment::FAILED,
                   failure_reason: Payment::FailureReason::TERMINAL_PAYPAL_FAILURE_REASONS)
            .order(created_at: :desc, id: :desc)
            .first
      end

      def still_blocked?(user)
        # A closed or suspended account is not going to be paid whatever they do, and an account
        # with a bank account on file is already being paid on a different rail — so telling either
        # one "your payouts stopped, fix your PayPal account and you'll be paid on the next payout
        # date" would be false. Suspension and closure are both checked before the payout method
        # is even considered (Payouts.is_user_payable), and a live bank account takes precedence
        # over PayPal (PaypalPayoutProcessor.is_user_payable), so none of these sellers is stuck
        # for the reason this note describes.
        #
        # The bank-account check matters on its own: switching to a bank usually clears
        # payment_address, but a seller who connected PayPal through OAuth keeps a payout email
        # via paypal_connect_account even after adding a bank, so the address-keyed check below
        # would still consider them blocked.
        return false if user.deleted? || user.suspended? || user.active_bank_account.present?

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
