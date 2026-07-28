# frozen_string_literal: true

# Decides whether a follow ("subscribe") submission has to pass a CAPTCHA, and
# which reCAPTCHA Enterprise key it should use.
#
# Why this exists: the follow endpoint makes Gumroad send an email, from our own
# sending domain, to any address someone types into it. A ring of accounts used
# that as a free phishing relay — they scripted the endpoint with harvested
# third-party addresses so that our "Please confirm your follow request" mail
# carried their lure, and pointed the confirm link at a storefront dressed up as
# a loan-approval notice. Refusing follows for suspended accounts (see
# Follower::CreateService) stops a ring only after we have caught it; a CAPTCHA
# stops the scripted submissions in the first place, because the whole scheme
# depends on volume that nobody is sitting there clicking through.
#
# Only sellers we have positively reviewed and marked `compliant`, whose account
# is still active, are trusted to take follows with no challenge. Everyone else —
# including `not_reviewed`, which is where every brand-new account starts and
# where all 76 ring accounts sat — gets the challenge. That is deliberately a
# wide net: the cost to a legitimate new creator is one CAPTCHA on their
# subscribe form until review clears them, and the cost of the alternative was
# ~364,000 unsolicited emails from our domain.
#
# Follows for suspended and deleted accounts are also refused outright, one layer
# down in Follower::CreateService. The `account_active?` check below is kept even
# so, deliberately: it is cheap, and it means this class states the whole trust
# rule on its own rather than depending on a caller elsewhere to have already
# filtered its input. Both checks are needed because suspending an account does
# not reset `user_risk_state` and deleting one does not touch it at all — a seller
# marked compliant before being shut down still reads as `compliant?` forever, so
# without the activity check they would keep taking follows with no challenge.
module FollowRecaptcha
  SURFACE = :follow

  class << self
    # A challenge is required unless the followed seller has been reviewed, marked
    # compliant, and still has an active (not suspended, not deleted) account.
    # Also requires a configured key: with no key there is no challenge the
    # browser could solve, so demanding one would just break the subscribe form
    # outright — that case is logged, so a missing key is visible in the logs
    # instead of silently turning the protection off.
    def required?(followed_user)
      return false if followed_user.blank?
      return false if followed_user.compliant? && followed_user.account_active?
      return true if site_key.present?

      Rails.logger.warn(
        "[follow_recaptcha] No reCAPTCHA site key is configured, so the follow CAPTCHA is off. " \
        "Set RECAPTCHA_MONEY_SITE_KEY, or RECAPTCHA_FOLLOW_SITE_KEY for a follow-specific key."
      )
      false
    end

    # Defaults to the key checkout already uses. It is a challenge-type
    # (non-score) key and is already authorized for every host the follow form
    # renders on, including seller custom domains, so this needs no new
    # provisioning. Set RECAPTCHA_FOLLOW_SITE_KEY to give the follow surface its
    # own key later — the score/threshold plumbing is per-surface, so a
    # dedicated key can be tuned without touching checkout.
    def site_key
      GlobalConfig.get("RECAPTCHA_FOLLOW_SITE_KEY").presence ||
        GlobalConfig.get("RECAPTCHA_MONEY_SITE_KEY")
    end
  end
end
