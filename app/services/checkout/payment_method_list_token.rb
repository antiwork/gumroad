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
# Both divergences fail the same way when they fail — the Element holding MORE methods than the
# intent (gumroad-private#1528) — so the list is issued once, signed, and echoed back at prepare
# rather than re-derived: one authority, sampled once.
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
    def issue(payment_method_types:, sellers:, quoted_payment_method_types: nil, inr_payment_method_types: nil, direct_listed_currency: nil, direct_listed_currency_rate: nil, permalinks: nil)
      return nil if payment_method_types.blank?

      payload = { "types" => payment_method_types.map(&:to_s), "sellers" => seller_ids(sellers) }
      # Quoted remounts leave USD (CAD, EUR, INR). Those Elements cannot list USD-only
      # methods, and an INR remount also adds UPI. Signing the remount lists here is what
      # lets prepare echo the list the Element actually mounted after the upgrade.
      payload["quoted_types"] = quoted_payment_method_types.map(&:to_s) if quoted_payment_method_types.present?
      payload["inr_types"] = inr_payment_method_types.map(&:to_s) if inr_payment_method_types.present?
      rate = positive_decimal(direct_listed_currency_rate)
      if direct_listed_currency.present? && rate.present?
        payload["direct_listed_currency"] = direct_listed_currency.to_s.downcase
        payload["direct_listed_currency_rate"] = rate.to_s("F")
        # Bind the signed rate to the cart it was issued for. Seller+currency alone lets a
        # rate from one of that seller's products be replayed onto another of their carts.
        bound = normalized_permalinks(permalinks)
        payload["permalinks"] = bound if bound.present?
      end

      verifier.generate(payload, purpose: PURPOSE, expires_in: TTL)
    end

    # The method list this checkout page mounted its Element with, or nil when the token is absent,
    # tampered with, expired, or was issued for different sellers — every one of which falls back to
    # re-resolving, i.e. today's behaviour. Never raises: a malformed token must not fail a checkout
    # that would otherwise succeed.
    #
    # `currency` is the Element's mount currency at pay time. A USD-priced cart starts in USD
    # (`types`) and may remount in the quoted currency (`quoted_types`) or INR (`inr_types`).
    # A non-USD mount without its remount key returns nil so prepare fails closed instead of
    # echoing the USD list onto an INR/CAD ConfirmationToken.
    def verify(token, sellers:, currency: nil)
      payload = verified_payload(token, sellers:)
      return nil unless payload

      types_for_currency(payload, currency)
    end

    # `permalinks` is the cart the rate is being read for. A token issued before the cart bind
    # shipped carries none, and keeps the seller+currency behaviour so a rolling deploy does not
    # strip the signed rate from pages already open; a token that carries them must match exactly.
    def direct_listed_currency_rate(token, sellers:, currency:, permalinks: nil)
      payload = verified_payload(token, sellers:)
      return nil unless payload
      return nil unless payload["direct_listed_currency"] == currency.to_s.downcase

      bound = payload["permalinks"]
      return nil if bound.present? && bound != normalized_permalinks(permalinks)

      positive_decimal(payload["direct_listed_currency_rate"])
    end

    private
      def seller_ids(sellers) = Array(sellers).compact.map(&:id).sort

      def normalized_permalinks(permalinks) = Array(permalinks).compact.map(&:to_s).uniq.sort

      def verified_payload(token, sellers:)
        return nil if token.blank?

        payload = verifier.verified(token.to_s, purpose: PURPOSE)
        return nil unless payload.is_a?(Hash)
        return nil unless payload["sellers"] == seller_ids(sellers)

        payload
      end

      def positive_decimal(value)
        rate = BigDecimal(value.to_s, exception: false)
        rate if rate&.positive?
      end

      def verifier = Rails.application.message_verifier(PURPOSE)

      def types_for_currency(payload, currency)
        mount = currency.to_s.downcase.presence
        if mount == "inr"
          return payload["inr_types"] if string_types?(payload["inr_types"])
          return payload["quoted_types"] if string_types?(payload["quoted_types"])
          return nil
        end
        if mount.present? && mount != "usd"
          return payload["quoted_types"] if string_types?(payload["quoted_types"])
          return nil
        end

        payload["types"] if string_types?(payload["types"])
      end

      def string_types?(types)
        types.is_a?(Array) && types.all? { _1.is_a?(String) } && types.present?
      end
  end
end
