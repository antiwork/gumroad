# frozen_string_literal: true

class StripeCardType
  CARD_TYPES = {
    "Visa" => CardType::VISA,
    "American Express" => CardType::AMERICAN_EXPRESS,
    "MasterCard" => CardType::MASTERCARD,
    "Discover" => CardType::DISCOVER,
    "JCB" => CardType::JCB,
    "Diners Club" => CardType::DINERS_CLUB,
    "UnionPay" => CardType::UNION_PAY
  }.freeze

  NEW_CARD_TYPES = {
    "visa" => CardType::VISA,
    "amex" => CardType::AMERICAN_EXPRESS,
    "mastercard" => CardType::MASTERCARD,
    "discover" => CardType::DISCOVER,
    "jcb" => CardType::JCB,
    "diners" => CardType::DINERS_CLUB,
    "unionpay" => CardType::UNION_PAY,
    "link" => CardType::LINK,
    # Local bank-transfer methods (Stripe reports them in payment_method_details.type,
    # never as a card brand). Mapping them here means a UPI or iDEAL charge records its
    # real method instead of falling through to "generic_card".
    "upi" => CardType::UPI,
    "ideal" => CardType::IDEAL
  }.freeze

  def self.to_card_type(stripe_card_type)
    type = CARD_TYPES[stripe_card_type]
    type = CardType::UNKNOWN if type.nil?
    type
  end

  def self.to_new_card_type(stripe_card_type)
    type = NEW_CARD_TYPES[stripe_card_type]
    type = CardType::UNKNOWN if type.nil?
    type
  end
end
