# frozen_string_literal: true

# The single server-issued payment-method list for one checkout page load.
#
# The Payment Element's payment_method_types must equal the deferred PaymentIntent's, or Stripe
# rejects the payment_method_types-scoped ConfirmationToken and the buyer cannot pay with ANY
# method, card included. Both sides used to derive that list independently by re-running
# Checkout::PaymentMethodResolver — the presenter at page load, Order::PreparePaymentIntentService
# at pay time — and two of the resolver's inputs are sampled from different requests:
#
#   * the Klarna amount window, from the mount-time cart total vs. the persisted purchase amounts;
#   * the buyer's country, from the checkout page's own remote_ip vs. the ip_country stamped at
#     order creation (a VPN toggled mid-checkout diverges them with no bug in either path).
#
# Both divergences fail the same way — the Element holding MORE methods than the intent
# (gumroad-private#1528) — so the list is issued once, signed, and echoed back at prepare rather
# than re-derived: one authority, sampled once.
#
# Signing (rather than trusting a plain parameter) is what keeps the echo from being a way to widen
# past a rollout gate — a client-supplied "us_bank_account" would otherwise re-enable ACH for a
# seller who never opted in (gumroad-private#1143). The payload binds the sellers it was issued
# for, so a token minted on a Klarna-enabled seller's checkout cannot be replayed onto another
# seller's cart.
class Checkout::PaymentMethodListToken
  # A checkout page older than this re-resolves at prepare exactly as it does today. Long enough to
  # cover a buyer who leaves the tab open through a coffee, short enough that a token cannot outlive
  # a same-day rollout change by much.
  TTL = 6.hours

  PURPOSE = "checkout_payment_method_list"

  class << self
    def issue(payment_method_types:, sellers:)
      return nil if payment_method_types.blank?

      verifier.generate(
        { "types" => payment_method_types.map(&:to_s), "sellers" => seller_ids(sellers) },
        purpose: PURPOSE,
        expires_in: TTL,
      )
    end

    # The method list this checkout page mounted its Element with, or nil when the token is absent,
    # tampered with, expired, or was issued for different sellers — every one of which falls back to
    # re-resolving, i.e. today's behaviour. Never raises: a malformed token must not fail a checkout
    # that would otherwise succeed.
    def verify(token, sellers:)
      return nil if token.blank?

      payload = verifier.verified(token.to_s, purpose: PURPOSE)
      return nil unless payload.is_a?(Hash)

      types = payload["types"]
      return nil unless types.is_a?(Array) && types.all? { _1.is_a?(String) } && types.present?
      return nil unless payload["sellers"] == seller_ids(sellers)

      types
    end

    private
      def seller_ids(sellers) = Array(sellers).compact.map(&:id).sort

      def verifier = Rails.application.message_verifier(PURPOSE)
  end
end
