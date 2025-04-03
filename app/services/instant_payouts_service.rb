# frozen_string_literal: true

class InstantPayoutsService
  attr_reader :seller, :date

  def initialize(seller, date: Date.today)
    @seller = seller
    @date = date
  end

  def perform
    return { success: false, error: "Your account is not eligible for instant payouts at this time." } unless seller.instant_payouts_supported?

    balances = seller.instantly_payable_balances
      .filter { |balance| balance.date <= date }
      .sort_by(&:created_at)
    return { success: false, error: "You need at least $10 in your balance to request an instant payout." } if balances.sum(&:holding_amount_cents) < Payouts::MINIMUM_INSTANT_PAYOUT_AMOUNT_CENTS

    if balances.any? { |balance| balance.holding_amount_cents > Payouts::MAXIMUM_INSTANT_PAYOUT_AMOUNT_CENTS }
      return { success: false, error: "Your balance exceeds the maximum instant payout amount. Please contact support for assistance." }
    end

    balances.each_with_object([[]]) do |balance, batches|
      if batches.last.sum(&:holding_amount_cents) + balance.holding_amount_cents > Payouts::MAXIMUM_INSTANT_PAYOUT_AMOUNT_CENTS
        batches << []
      end
      batches.last << balance
    end.then do |batches|
      results = batches.map do |batch|
        payment, payment_errors = Payouts.create_payment(
          batch.last.date,
          PayoutProcessorType::STRIPE,
          seller,
          payout_type: Payouts::PAYOUT_TYPE_INSTANT
        )

        if payment.present? && payment_errors.blank?
          StripePayoutProcessor.process_payments([payment])
          { success: !payment.failed? }
        else
          { success: false }
        end
      end

      if results.all? { |result| result[:success] }
        { success: true }
      else
        { success: false, error: "Failed to process instant payout" }
      end
    end
  end
end
