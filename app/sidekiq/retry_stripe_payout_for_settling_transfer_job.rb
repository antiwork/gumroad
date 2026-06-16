# frozen_string_literal: true

# Retries the bank payout for a Stripe payment whose funding internal transfer was still settling when
# the payout was first attempted. `StripePayoutProcessor.perform_payment` only creates the bank payout
# (the internal transfer happens once, in `prepare_payment_and_set_amount`), so re-running it against
# the same Payment never re-transfers funds.
class RetryStripePayoutForSettlingTransferJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform(payment_id)
    payment = Payment.find(payment_id)
    return unless payment.state == Payment::PROCESSING
    return if payment.stripe_transfer_id.present?

    StripePayoutProcessor.perform_payment(payment)
  end
end
