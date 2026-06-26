# frozen_string_literal: true

# Resolves which reCAPTCHA Enterprise key (and verification surface) a checkout
# request should use.
#
# Buyers in the `recaptcha_score_checkout` cohort get a score-based key, which
# never renders an interactive image challenge — it only returns a 0.0–1.0 risk
# score that we gate on server-side (see ValidateRecaptcha). Everyone else keeps
# the existing checkbox/challenge key, whose `tokenProperties.valid` is the only
# meaningful signal.
#
# The cohort is gated per logged-in buyer via Flipper so the new flow can be
# rolled out to specific users first. Anonymous buyers (nil user) are never in
# the cohort.
#
# The frontend (CheckoutPresenter) and the verifying controller
# (OrdersController) both read from here so the key the browser executes always
# matches the key we verify the token against — Google ties a token to the key
# that produced it.
module CheckoutRecaptcha
  COHORT_FEATURE = :recaptcha_score_checkout
  CHALLENGE_SURFACE = :checkout
  SCORE_SURFACE = :checkout_score

  class << self
    def score_based?(user)
      score_site_key.present? && Feature.active?(COHORT_FEATURE, user)
    end

    def site_key(user)
      score_based?(user) ? score_site_key : challenge_site_key
    end

    def surface(user)
      score_based?(user) ? SCORE_SURFACE : CHALLENGE_SURFACE
    end

    private
      def challenge_site_key
        GlobalConfig.get("RECAPTCHA_MONEY_SITE_KEY")
      end

      def score_site_key
        GlobalConfig.get("RECAPTCHA_MONEY_SCORE_SITE_KEY")
      end
  end
end
