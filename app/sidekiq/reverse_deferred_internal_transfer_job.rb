# frozen_string_literal: true

# Reverses a failed or returned payout's internal transfer that was held back while another payout to
# the same cross-border Connect account was waiting on its deferred bank payout.
class ReverseDeferredInternalTransferJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executing

  def perform(payment_id)
    payment = Payment.find(payment_id)
    return if payment.stripe_internal_transfer_id.nil?
    return unless payment.state.in?([Payment::FAILED, Payment::RETURNED, Payment::CANCELLED])
    return if fully_reversed?(payment)

    # Re-checks for a sibling still waiting (and reschedules), and holds payouts if the reversal fails.
    StripePayoutProcessor.reverse_internal_transfer_or_hold_payouts!(payment, payment.failure_reason, reraise: true)
  end

  private
    # An unreadable transfer falls through to the hold-aware path, which pauses payouts if it fails too.
    def fully_reversed?(payment)
      transfer = Stripe::Transfer.retrieve(payment.stripe_internal_transfer_id)
      transfer.amount_reversed.to_i >= transfer.amount.to_i
    rescue Stripe::StripeError
      false
    end
end
