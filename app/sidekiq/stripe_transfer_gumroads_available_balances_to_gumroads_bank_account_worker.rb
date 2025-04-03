# frozen_string_literal: true

class StripeTransferGumroadsAvailableBalancesToGumroadsBankAccountWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  BALANCE_BUFFER_CENTS = 1_000_000_00
  private_constant :BALANCE_BUFFER_CENTS

  def perform
    return unless Rails.env.production? || Rails.env.staging?
    return if Feature.active?(:skip_transfer_from_stripe_to_bank)

    next_payout_end_date = User::PayoutSchedule.next_scheduled_payout_end_date
    held_amount_cents = PayoutEstimates.estimate_held_amount_cents(next_payout_end_date, PayoutProcessorType::STRIPE)
    buffer_cents = BALANCE_BUFFER_CENTS + held_amount_cents[HolderOfFunds::GUMROAD]
    StripeTransferExternallyToGumroad.transfer_all_available_balances(buffer_cents:)
  end
end
