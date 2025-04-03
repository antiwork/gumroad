# frozen_string_literal: true

module ChargeableVisual
  module_function

  DEFAULT_FORMAT = "**** **** **** %s"
  LENGTH_TO_FORMAT = Hash.new(DEFAULT_FORMAT).merge(
    16 => DEFAULT_FORMAT,
    15 => "**** ****** *%s",
    14 => "**** ****** %s"
  )

  def is_cc_visual(visual)
    !(visual =~ /^[*\s\d]+$/).nil?
  end

  def build_visual(cc_number_last4, cc_number_length)
    cc_number_last4 = get_card_last4(cc_number_last4)
    format(LENGTH_TO_FORMAT[cc_number_length], cc_number_last4)
  end

  def get_card_last4(cc_number)
    cc_number.gsub(/[^\d]/, "").rjust(4, "*").slice(-4..-1)
  end

  def get_card_length_from_card_type(card_type)
    card_type_length_map = CreditCardUtility::CARD_TYPE_DEFAULT_LENGTHS
    length = card_type_length_map[card_type]
    length = card_type_length_map[CardType::UNKNOWN] if length.nil?
    length
  end
end
