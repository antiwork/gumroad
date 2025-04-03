# frozen_string_literal: true

class BraintreeCardType
  CARD_TYPES = {
    "Visa" => CardType::VISA,
    "American Express" => CardType::AMERICAN_EXPRESS,
    "MasterCard" => CardType::MASTERCARD,
    "Discover" => CardType::DISCOVER,
    "JCB" => CardType::JCB,
    "Diners Club" => CardType::DINERS_CLUB,
    CardType::PAYPAL => CardType::PAYPAL
  }.freeze

  def self.to_card_type(braintree_card_type)
    type = CARD_TYPES[braintree_card_type]
    type = CardType::UNKNOWN if type.nil?
    type
  end
end
