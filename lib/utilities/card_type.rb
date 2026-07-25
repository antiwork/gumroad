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
  # Bancontact, the debit-card scheme almost every Belgian bank issues. The buyer approves the
  # payment in their own banking app, so — like iDEAL above — no card network is involved from
  # Gumroad's side and nothing about it shows up as a card brand. Recording "bancontact" here is
  # what keeps the purchase's real payment method queryable in the database (and stops receipts
  # from promising a credit-card statement line that will never appear).
  BANCONTACT = "bancontact"
  # Buy-now-pay-later method offered through the same Payment Element. Not a card network
  # either: Klarna bills the buyer through their own Klarna account, so the purchase's
  # payment method has to be recorded here to stay queryable.
  KLARNA = "klarna"
end
