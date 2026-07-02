# frozen_string_literal: true

# Converts a gift purchase into a regular (non-gift) purchase.
#
# A gift is stored as two linked purchases: the gifter (payer) purchase carries the
# `is_gift_sender_purchase` flag, and the giftee (recipient, $0) purchase carries the
# `is_gift_receiver_purchase` flag. This service always clears the sender flag on the payer leg
# (that is the "gift purchase" being made regular) and retains the `Gift` row for audit history.
#
# For a gifted SUBSCRIPTION this flips `Subscription#gift?` (which reads
# `true_original_purchase.is_gift_sender_purchase?`) from true to false, re-points
# `subscription.user` at the paying buyer, and moves the payer's saved card onto the
# subscription, so renewal / manage-subscription comms AND billing resolve to the payer instead
# of the giftee.
#
# SCOPE — this moves BILLING OWNERSHIP, not product ACCESS. It does NOT mint a url_redirect /
# license for the payer (gift-sender purchases intentionally skip those at checkout); the giftee
# keeps the seat/license the seller already provisioned. Minting new access artifacts would
# double-provision (two live seats for one subscription). If a caller ever needs the payer to
# also hold the download/license, that is a separate, explicit reassignment step — out of scope.
#
# The giftee's receiver leg is left untouched. Its `is_gift_receiver_purchase` flag +
# `gift_receiver_purchase_successful` state are coherent together and keep the $0 access purchase
# visible in the recipient's library/mobile listings (for a subscription leg the flag is the ONLY
# reason it survives `Purchase.for_library`'s `not_subscription_or_original_purchase` scope).
# Clearing the flag would leave the row in a gift-only success state with non-gift flags — an
# inconsistent state that downstream non-gift success scopes (`NON_GIFT_SUCCESS_STATES`) exclude.
# The conversion only makes the PAYER's leg regular; the recipient keeps their gift access as-is.
#
# KNOWN LIMITATION (deliberately out of scope) — refund/chargeback propagation to the giftee leg
# is gated throughout the codebase on `is_gift_sender_purchase` (e.g. `Purchase::Refundable`,
# `Purchase::ChargeEventsHandler`, `Charge::Disputable`). Once this service clears that flag, a
# later refund or chargeback of the (now regular) payer purchase will NOT auto-revoke the giftee's
# $0 access leg. This is acceptable for the billing-ownership use case (the recipient is meant to
# keep the seat the seller provisioned, and for subscriptions the gift row only lives on the
# original purchase, so renewal reversals never propagated to the giftee regardless). If access
# must be revoked after a post-conversion reversal, do it explicitly — it is not automatic.
#
# This is a console/eng-invoked path (no controller/CLI). It is HARD-GATED on the caller
# asserting that BOTH the gifter and the giftee have signed off on the conversion.
#
#   Gift::ConvertToNonGiftService.new(
#     gift:,
#     gifter_signed_off: true,
#     giftee_signed_off: true,
#     admin_id: GUMROAD_ADMIN_ID,
#     reason: "SoftwareONE/Siemens re-own request, gumroad-private#841",
#   ).process!
#
class Gift::ConvertToNonGiftService
  class ConfirmationRequiredError < StandardError; end
  class NotConvertibleError < StandardError; end

  Result = Struct.new(:converted, :already_converted, :gift, :gifter_purchase, :giftee_purchase, :subscription, keyword_init: true)

  def initialize(gift:, gifter_signed_off:, giftee_signed_off:, admin_id: GUMROAD_ADMIN_ID, reason: nil)
    @gift = gift
    @gifter_signed_off = gifter_signed_off
    @giftee_signed_off = giftee_signed_off
    @admin_id = admin_id
    @reason = reason
  end

  def process!
    require_confirmation!

    gifter_purchase = gift.gifter_purchase
    giftee_purchase = gift.giftee_purchase

    raise NotConvertibleError, "Gift ##{gift.id} has no gifter purchase to convert" if gifter_purchase.nil?

    subscription = gifter_purchase.subscription

    ActiveRecord::Base.transaction do
      # Row-lock + re-check inside the transaction so two racing console invocations can't both
      # pass the idempotency guard and double-write the audit comments. The lock serializes them;
      # the loser re-reads the already-cleared flag and returns the already-converted result.
      gifter_purchase.lock!

      # Idempotent: if the gift-sender flag is already cleared, there is nothing to do.
      unless gifter_purchase.is_gift_sender_purchase?
        return Result.new(
          converted: false,
          already_converted: true,
          gift:,
          gifter_purchase:,
          giftee_purchase:,
          subscription:,
        )
      end

      gifter_purchase.update!(is_gift_sender_purchase: false)

      if subscription.present?
        # Re-own the subscription to the paying buyer. Gift subscriptions are created with
        # `subscription.user` pointing at the giftee and `subscription.credit_card` left nil, while
        # `Subscription#email` prefers `user.form_email` before falling back to `gift?`. So flipping
        # the sender flag alone would still route renewal/manage-subscription comms to the giftee
        # (whenever they have an account) AND leave renewals with no card for a guest payer. Point
        # the subscription at the payer and move the payer's saved card onto it (mirroring how a
        # regular subscription stores the original purchase's card). The card is assigned
        # UNCONDITIONALLY: a gift subscription's card can be non-nil if the giftee added their own
        # card through the manage-subscription flow (Subscription::UpdaterService), and
        # `Subscription#credit_card_to_charge` prefers `subscription.credit_card` over the owner's
        # account card. Conditionally assigning would leave that giftee card silently billing a
        # subscription now owned by and comms-routed to the payer. Overwriting with the payer's card
        # — or nil when the payer is a guest with no reusable card — clears the stale giftee card;
        # the guest payer then adds a card through the normal manage-subscription flow, same as any
        # owner without a saved card. The idempotency guard prevents a later re-run from clobbering
        # a card the payer adds afterward.
        subscription.update!(user: gifter_purchase.purchaser, credit_card: gifter_purchase.credit_card)
      end

      log_audit_comments!(gifter_purchase, giftee_purchase)
    end

    Result.new(
      converted: true,
      already_converted: false,
      gift:,
      gifter_purchase:,
      giftee_purchase:,
      subscription:,
    )
  end

  private
    attr_reader :gift, :admin_id, :reason

    def require_confirmation!
      return if @gifter_signed_off == true && @giftee_signed_off == true

      missing = []
      missing << "gifter" unless @gifter_signed_off == true
      missing << "giftee" unless @giftee_signed_off == true
      raise ConfirmationRequiredError,
            "Both gifter and giftee must sign off before converting gift ##{gift.id} " \
            "(missing sign-off: #{missing.join(', ')})"
    end

    def log_audit_comments!(gifter_purchase, giftee_purchase)
      content = audit_content
      gifter_purchase.comments.create!(content:, comment_type: Comment::COMMENT_TYPE_NOTE, author_id: admin_id)
      giftee_purchase&.comments&.create!(content:, comment_type: Comment::COMMENT_TYPE_NOTE, author_id: admin_id)

      # Also record it on the paying buyer's account (if they have one), since this is the
      # account that now owns the purchase/subscription.
      payer = gifter_purchase.purchaser
      payer&.comments&.create!(content:, comment_type: Comment::COMMENT_TYPE_NOTE, author_id: admin_id, purchase: gifter_purchase)
    end

    def audit_content
      parts = ["Gift ##{gift.id} converted to a regular (non-gift) purchase. " \
               "Confirmed sign-off from both gifter and giftee."]
      parts << "Reason: #{reason}" if reason.present?
      parts.join(" ")
    end
end
