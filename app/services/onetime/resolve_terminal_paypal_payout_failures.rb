# frozen_string_literal: true

# Explain the stopped payouts to the sellers who were already stuck when we shipped the fix.
#
# PayPal rejections 3148, 14159 and 3015 describe the receiving PayPal account, so re-sending the same
# payout can never succeed until the seller changes something. The payout pipeline retried them
# every week anyway — sellers here have a median of 22 identical failures each, worst case 37 — and
# told the seller nothing beyond a generic "payouts were paused by the system" note
# (gumroad-private#1478).
#
# The fix explains both codes and stops the retries for 3148 only: a 14159 seller can add US
# dollars to the account we already pay, which an address-keyed block would never notice, so they
# keep being retried. Either way the explanation is written by a payout that fails, or restored by
# the weekly walk when one gets buried — and a seller already behind the 3148 block has no next
# failure, while the walk's restore only reaches sellers who get as far as the PayPal processor
# (below the payout minimum or not compliant, Payouts exits first). Those sellers would keep seeing
# the same uninformative note they have been staring at for months, so this walks the existing
# population once and writes the note they should have had all along.
#
# Three things happen per seller, and each is skipped independently when it is already true, so the
# task is safe to re-run and safe to stop halfway:
#
# 1. The note, seller-visible on their Payouts page.
# 2. The email, because almost none of this population ever reaches the PayPal processor — earlier
#    gates (internal holds, balances below the payout minimum, the payout-cycle date) mean no Payment
#    is created, so there is no processing → failed transition and the live path never emails them.
#    Idempotent through the same `payout_date_of_last_paypal_terminal_failure_email` marker.
# 3. The invalidation, for retry-blocking rejections only: the unusable address comes off the account
#    so their payout settings stop showing a PayPal account we will never pay to. Same operation the
#    live path now performs (Payment#invalidate_paypal_payout_address); this reaches the sellers who
#    were already blocked and therefore have no next failure to trigger it.
module Onetime
  class ResolveTerminalPaypalPayoutFailures
    BATCH_SIZE = 500

    # Reports by default; writing needs dry_run: false said out loud.
    #
    # A bare .process in a production console would otherwise write a seller-visible note to every
    # seller in the population in one go — hundreds of accounts, no undo, and no chance to read the
    # list first. The safe order is: run it as-is, read what it says it would do, then re-run with
    # dry_run: false.
    def self.process(batch_size: BATCH_SIZE, dry_run: true)
      new.process(batch_size:, dry_run:)
    end

    def process(batch_size: BATCH_SIZE, dry_run: true)
      noted = 0
      emailed = 0
      invalidated = 0
      skipped = 0

      terminal_failures_by_user(batch_size:).each do |user_id, payment|
        user = User.find_by(id: user_id)
        if user.nil?
          skipped += 1
          next
        end

        # Only speak to sellers PayPal is still refusing right now. Someone who has since moved
        # to a bank account, changed PayPal address, or been paid out is no longer affected, and
        # telling them their payout could not be sent would be false.
        unless still_refused_by_paypal?(user)
          skipped += 1
          next
        end

        # Quote the rejection the seller is actually stuck on, not merely their newest one.
        payment = latest_terminal_failure_for_current_address(user) || payment

        did_something = false

        # Ordered first for the same reason as the live path — see Payment's transition callbacks.
        if should_invalidate?(user, payment)
          if dry_run
            puts "[dry run] would remove the PayPal payout address from User #{user.id}"
          else
            payment.invalidate_paypal_payout_address
            # The task and the payment hold separate copies of this seller, and the invalidation
            # wrote through the payment's. Reload so the note written below is generated against an
            # account that already has the address removed.
            user.reload
            puts "Removed the PayPal payout address from User #{user.id}"
          end
          invalidated += 1
          did_something = true
        end

        unless already_explained?(user, payment)
          if dry_run
            puts "[dry run] would explain #{payment.failure_reason} to User #{user.id}"
          else
            user.add_payout_note(content: payment.terminal_paypal_failure_seller_note, seller_visible: true)
            puts "Explained #{payment.failure_reason} to User #{user.id}"
          end
          noted += 1
          did_something = true
        end

        if should_email?(user)
          if dry_run
            puts "[dry run] would email User #{user.id} about #{payment.failure_reason}"
          else
            payment.send_paypal_terminal_failure_email
            puts "Emailed User #{user.id} about #{payment.failure_reason}"
          end
          emailed += 1
          did_something = true
        end

        skipped += 1 unless did_something
      end

      puts "Done. #{noted} explained, #{emailed} emailed, #{invalidated} addresses removed, #{skipped} skipped."
      { noted:, emailed:, invalidated:, skipped: }
    end

    private
      # Whether this seller still needs the email. Same marker the live path writes, so a seller the
      # weekly run did reach is not emailed twice, and re-running this task does not either.
      #
      # Deliberately not gated on the pause state or the balance minimum: those gates are exactly why
      # these sellers never get the email from the payout run, and the copy already tells a paused
      # seller that a hold is also in the way (Payment#terminal_paypal_failure_seller_solution).
      def should_email?(user)
        user.payout_date_of_last_paypal_terminal_failure_email.blank?
      end

      # Whether the unusable address still has to come off this account. Only the retry-blocking
      # rejection invalidates, and only a saved `payment_address` can be removed — the per-seller
      # checks live in Payment#invalidate_paypal_payout_address, which is the one place that decides,
      # so this only asks the cheap questions that decide whether to call it at all.
      def should_invalidate?(user, payment)
        payment.terminal_paypal_failure? && user.payment_address.present?
      end

      # One terminal failure per seller, to enumerate the population. No date bound on purpose: the
      # live block (PaypalPayoutProcessor.terminal_failure_blocking_payouts?) refuses a payout on a
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

      # Whether PayPal is still refusing this seller's payouts — not whether the retries are
      # stopped. The two differ for a currency rejection (14159), which is explained but still
      # retried, and this task exists to explain rather than to announce a block.
      #
      # ⚠️ Do not narrow `reasons` to RETRY_BLOCKING_PAYPAL_FAILURE_REASONS. It looks like the
      # tighter, safer set and it is the opposite: a currency-rejected seller's payouts fail every
      # single week, so they are the ones most in the dark, and for some of them nothing else ever
      # tells them. A self-paused seller is skipped by Payouts.is_user_payable at the
      # payouts_paused? gate, so no later payout fails to write the note, and that gate's own
      # re-explain is scoped to payouts_paused_internally?, which excludes them too. Narrowing
      # here is what would leave them reading "payouts were paused by the system" forever
      # (gumroad-private#1478). Pinned by the self-paused example in this task's spec.
      #
      # What makes the wider set safe is that the note describes the failed payout and the fix,
      # never a stopped retry: Payment#terminal_paypal_failure_seller_note branches on
      # Payment#terminal_paypal_failure? for that claim, so a 14159 seller reads the true
      # next-payout-date promise. Also pinned by spec.
      def still_refused_by_paypal?(user)
        # A closed or suspended account is not going to be paid whatever they do, so telling them
        # "your payouts stopped, fix your PayPal account and you'll be paid on the next payout date"
        # would be false. Both are checked before the payout method is even considered
        # (Payouts.is_user_payable), so neither is stuck for the reason this note describes.
        return false if user.deleted? || user.suspended?

        # Everything else — a bank account on file, a changed PayPal address, a payout that
        # succeeded since the rejection — is asked of the live check itself rather than
        # re-implemented here, so this note can only reach sellers PayPal really is refusing. A
        # second copy of that logic would drift, and the drift would be us telling sellers
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
