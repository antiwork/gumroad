# frozen_string_literal: true

# CardDataHandlingError is an error from the front-end when the card data was being handled and failed for some reason.
class CardDataHandlingError
  attr_reader :card_error_code, :error_message

  # Public: Initialize the error with an error message and card error code. If the card error code is nil the error
  # is assumed to not be a card error.
  #
  # error_message - The error message to log/persist for this error
  # card_error_code -
  def initialize(error_message, card_error_code = nil)
    @error_message = error_message
    @card_error_code = card_error_code
  end

  # Public: Indicates if the error this object represents is an card error or some other error. Card errors are errors
  # specifically relating to the card that's been presented, where-as other errors may have to do with connectivity
  # with the payment processor, or any other non-card issue.
  #
  # Returns: true if the error is a card error, false if not
  def is_card_error?
    !card_error_code.nil?
  end
end
