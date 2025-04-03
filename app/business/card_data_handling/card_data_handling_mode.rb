# frozen_string_literal: true

module CardDataHandlingMode
  TOKENIZE_VIA_STRIPEJS = "stripejs.0"
  VALID_MODES = {
    TOKENIZE_VIA_STRIPEJS => StripeChargeProcessor.charge_processor_id
  }.freeze

  module_function

  def is_valid(card_data_handling_mode)
    return false if card_data_handling_mode.nil?

    card_data_handling_modes = card_data_handling_mode.split(",")
    (card_data_handling_modes - VALID_MODES.keys).empty?
  end

  def get_card_data_handling_mode(_seller)
    [
      TOKENIZE_VIA_STRIPEJS
    ].join(",")
  end
end
