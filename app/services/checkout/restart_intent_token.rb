# frozen_string_literal: true

# Signed proof that the buyer asked for this membership on this checkout page load. It is never
# written to the cart, so a saved line cannot carry it forward, and `issued_at` must postdate the
# buyer's latest deactivation so a tab opened before a cancellation cannot revive it.
class Checkout::RestartIntentToken
  TTL = 1.hour

  PURPOSE = "checkout_restart_intent"

  class << self
    # Guests are signed too (buyer_id nil), because a logged-out buyer restarts by typing the email
    # of the cancelled membership and goes through the same stale-line path.
    def issue(product:, buyer:)
      payload = { "product_id" => product.id, "buyer_id" => buyer&.id, "issued_at" => Time.current.to_f }
      verifier.generate(payload, purpose: PURPOSE, expires_in: TTL)
    end

    # Never raises: a missing, malformed, expired, or foreign token reads as "no intent", which
    # refuses the restart rather than failing the whole order.
    def restart_intended?(token, product:, buyer:, lapsed_at:)
      return false if token.blank?

      payload = verifier.verified(token.to_s, purpose: PURPOSE)
      return false unless payload.is_a?(Hash)
      return false unless payload["product_id"] == product.id && payload["buyer_id"] == buyer&.id

      issued_at = Float(payload["issued_at"], exception: false)
      issued_at.present? && issued_at >= lapsed_at.to_f
    end

    private
      def verifier = Rails.application.message_verifier(PURPOSE)
  end
end
