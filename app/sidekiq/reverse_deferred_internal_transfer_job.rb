# frozen_string_literal: true

# Reverses a failed or returned payout's internal transfer that was held back while another payout to
# the same cross-border Connect account was waiting on its deferred bank payout.
class ReverseDeferredInternalTransferJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executing

  # If the transfer stays unreadable through every retry, fail closed: the hold-aware path pauses
  # payouts when its own reversal attempt fails, so the returned balance cannot be paid out again.
  sidekiq_retries_exhausted do |job, _exception|
    payment = Payment.find_by(id: job["args"].first)
    next if payment.nil? || payment.stripe_internal_transfer_id.nil?

    StripePayoutProcessor.reverse_internal_transfer_or_hold_payouts!(payment, payment.failure_reason)
  end

  def perform(payment_id)
    payment = Payment.find(payment_id)
    return if payment.stripe_internal_transfer_id.nil?
    return unless payment.state.in?([Payment::FAILED, Payment::RETURNED, Payment::CANCELLED])

    transfer = Stripe::Transfer.retrieve(payment.stripe_internal_transfer_id)
    # Skip only when the transfer is reversed and its difference credit is recorded; a reversal whose
    # credit write rolled back still owes that credit, which the processor records without re-reversing.
    return if transfer.amount_reversed.to_i >= transfer.amount.to_i && payment.credit.present?

    # Re-checks for a sibling still waiting (and reschedules), and holds payouts if the reversal fails.
    StripePayoutProcessor.reverse_internal_transfer_or_hold_payouts!(payment, payment.failure_reason, reraise: true)
  end
end
