# frozen_string_literal: true

module StripeErrorHandler
  private
    def with_stripe_error_handler
      yield
    rescue Stripe::InvalidRequestError => e
      raise ChargeProcessorInvalidRequestError.new(original_error: e)
    rescue Stripe::APIConnectionError, Stripe::APIError => e
      raise ChargeProcessorUnavailableError.new(original_error: e)
    rescue Stripe::CardError => e
      error_code, charge_id = get_card_error_details(e)
      raise ChargeProcessorCardError.new(error_code, e.message, original_error: e, charge_id:)
    rescue Stripe::RateLimitError => e
      raise ChargeProcessorErrorRateLimit.new(original_error: e)
    rescue Stripe::StripeError => e
      raise ChargeProcessorErrorGeneric.new(e.code, original_error: e)
    end

    def get_card_error_details(error)
      error_details = error.json_body[:error]
      error_code = error.code

      # If available, the reason for a card decline (found in Stripe's `decline_code`
      # attribute) will appended to the error code returned to us by Stripe. Examples:
      # | Stripe's error code | Stripe's decline code | Gumroad's error_code     |
      # | :------------------ | :-------------------- | :----------------------- |
      # | card_declined       | generic_decline       | card_declined_generic_decline |
      # | card_declined       | fraudulent            | card_declined_fraudulent |
      # | incorrect_cvc       |                       | incorrect_cvc            |
      decline_code = error_details[:decline_code]
      error_code += "_#{decline_code}" if error_code == "card_declined" && decline_code.present?

      [error_code, error_details[:charge]]
    end
end
