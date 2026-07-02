# frozen_string_literal: true

class CardType
  UNKNOWN = "generic_card"
  VISA = "visa"
  AMERICAN_EXPRESS = "amex"
  MASTERCARD = "mastercard"
  DISCOVER = "discover"
  JCB = "jcb"
  DINERS_CLUB = "diners"
  PAYPAL = "paypal"
  UNION_PAY = "unionpay"
  # Stripe Link is a wallet, not a card network; mirrors the PAYPAL precedent for
  # non-card payment methods surfaced through card_type.
  LINK = "link"
end
