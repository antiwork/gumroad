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
  SCORE_TRUSTED_SURFACE = :checkout_score_trusted
  # A qualifying purchase must be at least this old. Without an age floor a
  # fraudster could buy a single cheap product from any compliant seller and
  # immediately inherit the lenient score bar; a years-old purchase can't be
  # manufactured on demand.
  MIN_TRUSTED_PURCHASE_AGE = 5.years

  class << self
    def score_based?(user)
      score_site_key.present? && Feature.active?(COHORT_FEATURE, user)
    end

    # `challenge_fallback` is a buyer coming back after a score-only refusal, re-proving
    # themselves against the challenge key (gumroad-private#1590). That key is the only one that
    # can escalate to an interactive image challenge, and CHALLENGE_SURFACE carries no score
    # threshold — which is the whole point: a score can only ever refuse a risky-looking session,
    # while a passed challenge is positive evidence. It is the same key and surface every buyer
    # outside the cohort already checks out against, so no threshold moves and the cohort's
    # standard bar is untouched.
    def site_key(user, challenge_fallback: false)
      return challenge_site_key if challenge_fallback

      score_based?(user) ? score_site_key : challenge_site_key
    end

    # Trusted buyers in the score cohort get their own verification surface,
    # which carries a lower score threshold (see ValidateRecaptcha's
    # RECAPTCHA_SCORE_THRESHOLD_DEFAULTS). The site key is identical to the
    # untrusted score surface — only the server-side threshold differs — so the
    # frontend is unaffected.
    def surface(user, challenge_fallback: false)
      return CHALLENGE_SURFACE if challenge_fallback || !score_based?(user)

      trusted_buyer?(user) ? SCORE_TRUSTED_SURFACE : SCORE_SURFACE
    end

    # Public because the challenge fallback needs it in two places the cohort logic can't answer:
    # the checkout page has to be given the key to execute, and the verifying controller has to
    # know the key exists at all before it honours a fallback marker.
    def challenge_site_key
      GlobalConfig.get("RECAPTCHA_MONEY_SITE_KEY")
    end

    private
      # A buyer is trusted when they are a compliant seller themselves, or have a
      # paid purchase from a currently-compliant seller made at least
      # MIN_TRUSTED_PURCHASE_AGE ago. Both signal a real, established account
      # rather than a throwaway used for fraud, so we can afford a more lenient
      # score bar for them. Anonymous buyers (nil — possible when the cohort
      # feature is enabled globally rather than per-user) have no account to
      # vouch for them, so they're never trusted and fall to the standard score
      # surface.
      def trusted_buyer?(user)
        return false if user.nil?

        user.compliant? || established_buyer_of_compliant_seller?(user)
      end

      def established_buyer_of_compliant_seller?(user)
        user.purchases.paid
            .where(created_at: ..MIN_TRUSTED_PURCHASE_AGE.ago)
            .joins(:seller).merge(User.compliant)
            .exists?
      end

      def score_site_key
        GlobalConfig.get("RECAPTCHA_MONEY_SCORE_SITE_KEY")
      end
  end
end
