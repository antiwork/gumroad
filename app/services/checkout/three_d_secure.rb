# frozen_string_literal: true

# Asks Stripe to authenticate card charges with 3DS where a buyer is present to
# complete it. Only possible on customer-present intents: an off-session rebill
# has nobody to authenticate.
#
# What this buys is liability, not friction: a successfully authenticated charge
# later reported as fraud is normally the issuer's loss, so the dispute never
# lands on us. The issuer may satisfy the request without showing the buyer
# anything (frictionless 3DS), and a card that cannot be authenticated is
# unaffected ("any" = authenticate when the card supports it).
#
# Flag-scoped per seller so a cohort can be piloted before the cost (some buyers
# abandon at the challenge) lands on all sales.
class Checkout::ThreeDSecure
  FEATURE = :card_3ds_challenge

  # Stripe rejects card options on an intent that does not offer card, so callers
  # must already know the intent is card-scoped.
  REQUEST_PARAMS = { payment_method_options: { card: { request_three_d_secure: "any" } } }.freeze

  def self.request?(seller = nil)
    Feature.active?(FEATURE, seller)
  end
end
