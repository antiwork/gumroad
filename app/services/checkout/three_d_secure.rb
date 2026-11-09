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
  CARD_PAYMENT_METHOD_TYPE = "card"

  REQUEST_PARAMS = { payment_method_options: { card: { request_three_d_secure: "any" } } }.freeze

  def self.request?(seller = nil)
    Feature.active?(FEATURE, seller)
  end

  # Stripe rejects card payment_method_options on an intent whose payment_method_types
  # does not offer card, so callers ask about the params they are actually sending
  # instead of assuming the intent is card-scoped.
  def self.card_scoped?(params)
    Array(params[:payment_method_types]).map(&:to_s).include?(CARD_PAYMENT_METHOD_TYPE)
  end
end
