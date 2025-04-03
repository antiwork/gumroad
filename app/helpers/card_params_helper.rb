# frozen_string_literal: true

module CardParamsHelper
  module_function
  # Public: Gets the card data handling mode that's indicated in the card parameters.
  # params - the params received containing posted data and the card_data_handling_mode parameter
  # Returns: a string indicating the card data handling mode or nil if it is not known, undefined or not valid.
  def get_card_data_handling_mode(params)
    card_data_handling_mode = params[:card_data_handling_mode]
    return card_data_handling_mode if CardDataHandlingMode.is_valid(card_data_handling_mode)
    nil
  end

  # Public: Checks for an error provided in the card params and returns an object wrapping up the error if there is one.
  def check_for_errors(params)
    if params.key?(:stripe_error)
      stripe_error = params[:stripe_error]
      return CardDataHandlingError.new(stripe_error[:message], stripe_error[:code]) if stripe_error
    end
    nil
  end

  # Public: Initialize a card data object from params data received in an external request.
  def build_chargeable(params, gumroad_guid = nil)
    ChargeProcessor.get_chargeable_for_params(params, gumroad_guid)
  end
end
