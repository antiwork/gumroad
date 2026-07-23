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
  # Local bank-transfer methods offered through Stripe's Payment Element (UPI in India,
  # iDEAL in the Netherlands). Like PAYPAL and LINK above, these are not card networks,
  # but recording the method here keeps every purchase's payment method queryable from
  # the database instead of requiring a walk of Stripe's API to classify them.
  UPI = "upi"
  IDEAL = "ideal"
end
