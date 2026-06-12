# frozen_string_literal: true

# Restores balances stranded in `processing` by PayPal payouts that reversed (or
# returned) directly from the `processing` state before PR #5177 shipped. See
# issue #486.
#
# Before #5177 the only balance-restoring callback for a reversal was
# `after_transition unclaimed: [... reversed returned ...]`, so a payout that
# reversed straight from `processing` (never going `unclaimed`) left its balances
# stuck in `processing` — the funds never re-entered the payout queue and the
# seller's unpaid balance showed $0.00. The forward fix added
# `after_transition processing: [reversed returned] => mark_balances_as_unpaid`
# (app/models/payment.rb), but it did not backfill balances stranded earlier.
#
# This task re-finds every PayPal payment in a `reversed`/`returned` state whose
# balances are still `processing` and flips those balances back to `unpaid`,
# matching what the forward fix would have done. Each balance is re-validated at
# write time and skipped if it is still held by any active or completed payout, so
# a balance legitimately in-flight on a newer payment is never touched.
module Onetime
  class RestoreStrandedPaypalReversalBalances
    BATCH_SIZE = 100

    # A balance still owed to a live payout must not be reverted. A balance is
    # rightfully held in `processing` while any of its payments is still in a
    # non-terminal state, so delegate to the model's own constant to stay in sync.
    HOLDING_PAYMENT_STATES = Payment::NON_TERMINAL_STATES

    def self.process(dry_run: true, payment_ids: nil)
      new.process(dry_run:, payment_ids:)
    end

    def process(dry_run: true, payment_ids: nil)
      stats = Hash.new(0)

      candidate_payments(payment_ids).find_in_batches(batch_size: BATCH_SIZE) do |batch|
        ReplicaLagWatcher.watch

        batch.each do |payment|
          stats[:payments_scanned] += 1

          stuck_balances = payment.balances.processing.to_a
          next if stuck_balances.empty?

          stats[:payments_with_stuck_balances] += 1

          stuck_balances.each do |balance|
            unless restorable?(balance)
              stats[:balances_skipped_still_held] += 1
              puts "skip balance #{balance.id} (payment #{payment.id}): still held by an active payout"
              next
            end

            if dry_run
              stats[:balances_would_restore] += 1
              puts "DRY-RUN restore balance #{balance.id} (#{balance.amount_cents}c) payment #{payment.id} user #{payment.user_id}"
              next
            end

            balance.mark_unpaid!
            stats[:balances_restored] += 1
            puts "restored balance #{balance.id} (#{balance.amount_cents}c) payment #{payment.id} user #{payment.user_id}"
          end
        end
      end

      puts "done: #{stats.to_h}"
      stats.to_h
    end

    private
      def candidate_payments(payment_ids)
        scope = Payment.processed_by(PayoutProcessorType::PAYPAL)
                       .where(state: [Payment::REVERSED, Payment::RETURNED])
        scope = scope.where(id: payment_ids) if payment_ids.present?
        scope
      end

      def restorable?(balance)
        balance.processing? &&
          balance.payments.where(state: HOLDING_PAYMENT_STATES).none?
      end
  end
end
