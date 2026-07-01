# frozen_string_literal: true

# Server-authoritative policy boundary for the client-confirmed Intent path (Lane B). Given a cart's
# sellers and product lifecycle, it decides whether the cart may confirm client-side and which Stripe
# payment methods it may use. The frontend must never widen this: the presenter feeds the resolved
# payment_method_types to the Payment Element and Order::PreparePaymentIntentService feeds the same
# value to the deferred PaymentIntent, so the two sides cannot drift.
#
# Two method sets are distinguished:
#   - eligible_payment_method_types: the policy set the cart *could* use per the origin decision memo
#     ("Payment-method eligibility by product type"). This is the logged decision and what later units
#     intersect with per-method launch/PPP gates.
#   - payment_method_types: what Stripe actually receives on the client-confirmed path today. Only card
#     is launched — redirect methods need the return page + allow_redirects (U10/U11), inline
#     wallets/Link need frontend verification (U9), and connected-account scoping needs U12. Widening
#     LAUNCHED_PAYMENT_METHOD_TYPES is a later unit's job, and the deferred intent's payment_method_types
#     moves with it automatically because both sides read this resolver (the Bug 1 handshake invariant).
#
# Always an explicit array, never Stripe's automatic_payment_methods: Stripe refuses to confirm a
# payment_method_types-scoped ConfirmationToken (which the Payment Element mints) against an
# automatic_payment_methods intent.
class Checkout::PaymentMethodResolver
  # Buyer-present single-seller dynamic set (memo single-buy row). Apple Pay / Google Pay ride on
  # "card" in the Payment Element, so they are not separate types here.
  ONE_TIME_PAYMENT_METHOD_TYPES = %w[card link klarna afterpay_clearpay affirm ideal bancontact cashapp].freeze
  # Afterpay/Clearpay and Affirm are one-time, buyer-present only (memo), so a recurring lifecycle drops them.
  RECURRING_INELIGIBLE_PAYMENT_METHOD_TYPES = %w[afterpay_clearpay affirm].freeze
  # Only card is launched on the client-confirmed path today; later units widen this (see class comment).
  LAUNCHED_PAYMENT_METHOD_TYPES = %w[card].freeze
  # Multi-seller and other Lane A carts keep Gumroad's existing card + PayPal set.
  LANE_A_PAYMENT_METHOD_TYPES = %w[card paypal].freeze

  Resolution = Data.define(:client_confirm_eligible, :payment_method_types, :eligible_payment_method_types, :fallback_reason) do
    def client_confirm_eligible? = client_confirm_eligible
  end

  def initialize(sellers:, recurring: false, commission: false, setup_for_future: false)
    @sellers = sellers
    @recurring = recurring
    @commission = commission
    @setup_for_future = setup_for_future
  end

  def resolve
    @resolve ||= begin
      reason = ineligibility_reason
      eligible = eligible_method_policy
      resolution = Resolution.new(
        client_confirm_eligible: reason.nil?,
        # Nil on Lane A carts: they never mount the client-confirmed Payment Element, so there is no
        # Stripe method list to hand them. Non-nil only when the cart confirms client-side.
        payment_method_types: reason.nil? ? eligible & LAUNCHED_PAYMENT_METHOD_TYPES : nil,
        eligible_payment_method_types: eligible,
        fallback_reason: reason
      )
      log_decision(resolution)
      resolution
    end
  end

  private
    attr_reader :sellers, :recurring, :commission, :setup_for_future

    # Mirrors Checkout::StripePaymentPresenter#client_confirm_eligible? gates (single-seller, non-connect,
    # one-time) as an ordered set of reasons, so a blocked cart records *why* it stayed on Lane A.
    def ineligibility_reason
      return "multi_seller" unless sellers.one?
      return "direct_charge_seller" if sellers.any?(&:stripe_connect_account)
      return "recurring_charge" if recurring
      return "commission" if commission
      return "setup_flow" if setup_for_future
      nil
    end

    def eligible_method_policy
      return LANE_A_PAYMENT_METHOD_TYPES unless sellers.one?

      methods = ONE_TIME_PAYMENT_METHOD_TYPES
      methods -= RECURRING_INELIGIBLE_PAYMENT_METHOD_TYPES if recurring
      methods
    end

    def log_decision(resolution)
      launch_gated_out = resolution.eligible_payment_method_types - Array(resolution.payment_method_types)
      Rails.logger.info(
        "[#{self.class.name}] client_confirm_eligible=#{resolution.client_confirm_eligible} " \
        "seller_ids=#{sellers.map { _1&.id }} recurring=#{recurring} commission=#{commission} " \
        "setup_for_future=#{setup_for_future} fallback_reason=#{resolution.fallback_reason.inspect} " \
        "eligible=#{resolution.eligible_payment_method_types} enabled=#{resolution.payment_method_types.inspect} " \
        "launch_gated_out=#{launch_gated_out}"
      )
    end
end
