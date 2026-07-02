# frozen_string_literal: true

# Server-authoritative policy boundary for the client-confirmed Intent path (Lane B). Given a cart's
# sellers and product lifecycle, it decides whether the cart may confirm client-side and which Stripe
# payment methods it may use. The frontend cannot widen this: payment_method_types is the intersection
# of the eligible set with a hardcoded launched set, so no client-supplied value can add a method.
#
# Two method sets are distinguished:
#   - eligible_payment_method_types: the policy set the cart *could* use (the eligibility-by-product-type
#     policy). This is the logged decision and what later units intersect with per-method launch/PPP gates.
#   - payment_method_types: what Stripe actually receives on the client-confirmed path today. Only card
#     is launched unconditionally; Link joins it per-seller behind :stripe_payment_element_link, reusing
#     Lane A's flag so the two lanes launch Link together. The remaining methods need machinery that
#     isn't built yet: redirect methods need allow_redirects enablement, and delayed-notification
#     methods need pending UX. Widening the launched set further is a later unit's job.
#
# Handshake note: the deferred PaymentIntent's payment_method_types must equal the Payment Element's or
# Stripe rejects the ConfirmationToken (which is payment_method_types-scoped, so it also can't be
# confirmed against an automatic_payment_methods intent — hence an explicit array here, never
# automatic_payment_methods). Both sides read this resolver, but they derive its lifecycle inputs
# independently (the presenter from the cart, PreparePaymentIntentService from the persisted purchases).
# Today that can't diverge because card survives every filter, so both land on ["card"]. When LAUNCHED
# widens, those two derivations must be reconciled — and PreparePaymentIntentService hard-stops an
# ineligible cart before creating the intent, so any residual mismatch fails closed rather than reaching
# Stripe with the wrong method list.
class Checkout::PaymentMethodResolver
  # Buyer-present single-seller dynamic set. Apple Pay / Google Pay ride on "card" in the Payment
  # Element, so they are not separate types here.
  ONE_TIME_PAYMENT_METHOD_TYPES = %w[card link klarna afterpay_clearpay affirm ideal bancontact cashapp].freeze
  # Afterpay/Clearpay and Affirm are one-time, buyer-present only, so a recurring lifecycle drops them.
  RECURRING_INELIGIBLE_PAYMENT_METHOD_TYPES = %w[afterpay_clearpay affirm].freeze
  # Card is always launched on the client-confirmed path; later units widen this (see class comment).
  LAUNCHED_PAYMENT_METHOD_TYPES = %w[card].freeze
  # Link launches per-seller behind Lane A's existing flag (see #launched_payment_method_types).
  LINK_PAYMENT_METHOD_TYPE = "link"
  # Multi-seller and other Lane A carts keep Gumroad's existing card + PayPal set.
  LANE_A_PAYMENT_METHOD_TYPES = %w[card paypal].freeze

  Resolution = Data.define(:client_confirm_eligible, :payment_method_types, :eligible_payment_method_types, :fallback_reason, :stripe_connect_account_id) do
    def client_confirm_eligible? = client_confirm_eligible

    # One source of truth for the Payment Element's Link toggle: Link renders iff the intent will
    # accept a link-type payment method, so the Element and the deferred intent cannot drift.
    def stripe_link_enabled? = Array(payment_method_types).include?(LINK_PAYMENT_METHOD_TYPE)
  end

  def initialize(sellers:, recurring: false, commission: false, setup_for_future: false)
    @sellers = sellers
    @recurring = recurring
    @commission = commission
    @setup_for_future = setup_for_future
  end

  def resolve
    @resolution ||= begin
      reason = ineligibility_reason
      eligible = eligible_method_policy
      resolution = Resolution.new(
        client_confirm_eligible: reason.nil?,
        # Nil on Lane A carts: they never mount the client-confirmed Payment Element, so there is no
        # Stripe method list to hand them. Non-nil only when the cart confirms client-side.
        payment_method_types: reason.nil? ? eligible & launched_payment_method_types : nil,
        eligible_payment_method_types: eligible,
        fallback_reason: reason,
        stripe_connect_account_id: reason.nil? ? stripe_connect_account_id : nil
      )
      log_decision(resolution)
      resolution
    end
  end

  private
    attr_reader :sellers, :recurring, :commission, :setup_for_future

    # The client-confirm cart-shape gates (single-seller, non-connect, one-time), owned here and applied
    # as an ordered set of reasons so a blocked cart records *why* it stayed on Lane A.
    def ineligibility_reason
      return "multi_seller" unless sellers.one?
      return "direct_charge_account_unlinked" if direct_charge_seller? && stripe_connect_account_id.blank?
      return "recurring_charge" if recurring
      return "commission" if commission
      return "setup_flow" if setup_for_future
      nil
    end

    def direct_charge_seller?
      sellers.one? && sellers.first.has_stripe_account_connected?
    end

    def stripe_connect_account_id
      return nil unless direct_charge_seller?
      sellers.first.stripe_connect_account&.charge_processor_merchant_id
    end

    def eligible_method_policy
      return LANE_A_PAYMENT_METHOD_TYPES unless sellers.one?

      methods = ONE_TIME_PAYMENT_METHOD_TYPES
      methods -= RECURRING_INELIGIBLE_PAYMENT_METHOD_TYPES if recurring
      methods
    end

    # The launched set is per-seller: Link requires the seller-scoped :stripe_payment_element_link
    # flag (the same flag that gates Link on the server-confirm lane, so both lanes move together).
    # PPP note: a Link payment method has no card country in the ConfirmationToken preview, so a
    # PPP-discounted purchase paid via Link fails the existing card-country check (fails closed,
    # buyer retries with a card). The PPP method matrix (U13) will gate Link out of PPP checkouts
    # pre-render instead.
    def launched_payment_method_types
      return LAUNCHED_PAYMENT_METHOD_TYPES unless link_launched?

      LAUNCHED_PAYMENT_METHOD_TYPES + [LINK_PAYMENT_METHOD_TYPE]
    end

    def link_launched?
      sellers.one? && Feature.active?(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_LINK_FEATURE_NAME, sellers.first)
    end

    def log_decision(resolution)
      launch_gated_out = resolution.eligible_payment_method_types - Array(resolution.payment_method_types)
      Rails.logger.info(
        "[#{self.class.name}] client_confirm_eligible=#{resolution.client_confirm_eligible} " \
        "seller_ids=#{sellers.map { _1&.id }} recurring=#{recurring} commission=#{commission} " \
        "setup_for_future=#{setup_for_future} fallback_reason=#{resolution.fallback_reason.inspect} " \
        "eligible=#{resolution.eligible_payment_method_types} enabled=#{resolution.payment_method_types.inspect} " \
        "launch_gated_out=#{launch_gated_out} stripe_connect_account_id=#{resolution.stripe_connect_account_id.inspect}"
      )
    end
end
