# frozen_string_literal: true

class Admin::PaymentPresenter
  attr_reader :payment

  def initialize(payment:)
    @payment = payment
  end

  def props
    {
      external_id: payment.external_id,
      displayed_amount: payment.displayed_amount,
      payout_period_end_date: payment.payout_period_end_date,
      created_at: payment.created_at,
      user: payment.user ? {
        external_id: payment.user.external_id,
        name: payment.user.name,
      } : nil,

      # State
      state: payment.state,
      humanized_failure_reason: payment.humanized_failure_reason,
      failed: payment.failed?,
      cancelled: payment.cancelled?,
      returned: payment.returned?,
      processing: payment.processing?,
      unclaimed: payment.unclaimed?,
      non_terminal_state: Payment::NON_TERMINAL_STATES.include?(payment.state),

      # Processor
      processor: payment.processor,
      is_stripe_processor: payment.processor == PayoutProcessorType::STRIPE,
      is_paypal_processor: payment.processor == PayoutProcessorType::PAYPAL,
      processor_fee_cents: payment.processor_fee_cents,

      # Stripe-specific
      stripe_transfer_id: payment.stripe_transfer_id,
      stripe_transfer_url: StripeUrl.transfer_url(payment.stripe_transfer_id, account_id: payment.stripe_connect_account_id),
      stripe_connected_account_url: StripeUrl.connected_account_url(payment.stripe_connect_account_id),
      stripe_connect_account_id: payment.stripe_connect_account_id,
      bank_account: payment.bank_account ? {
        formatted_account: payment.bank_account.formatted_account,
        credit_card: { visual: payment.bank_account.credit_card&.visual },
      } : nil,

      # PayPal-specific
      txn_id: payment.txn_id,
      payment_address: payment.payment_address,
      correlation_id: payment.correlation_id,

      # Split mode
      was_created_in_split_mode: payment.was_created_in_split_mode,
      split_payments_info: payment.split_payments_info,
    }
  end
end
