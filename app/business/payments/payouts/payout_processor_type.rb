# frozen_string_literal: true

module PayoutProcessorType
  PAYPAL = "PAYPAL"
  ACH = "ACH" # Retired. Kept because we still have payments in the database for this processor.
  ZENGIN = "ZENGIN" # Retired. Kept because we still have payments in the database for this processor, and validations for them.
  STRIPE = "STRIPE"

  ALL = {
    PAYPAL => PaypalPayoutProcessor,
    STRIPE => StripePayoutProcessor
  }.freeze
  private_constant :ALL

  def self.all
    ALL.keys
  end

  def self.get(payout_processor_type)
    ALL[payout_processor_type]
  end
end
