# frozen_string_literal: true

# Fetches and caches which payment methods a Stripe Connect (direct-charge) seller's own
# Stripe account can accept, keyed off the account's capabilities.
#
# Why this exists: charges for a direct-charge seller are created on the seller's Stripe
# account, not Gumroad's platform account, and payment method capabilities are per-account.
# Stripe rejects a PaymentIntent create outright when payment_method_types lists a method the
# account hasn't activated — which fails the whole checkout even when the buyer picked a plain
# card (see gumroad-private#1026). So checkout must only offer methods on accounts that
# actually have them. Standard Connect accounts manage their own capabilities (the platform
# cannot request capabilities on the seller's behalf), which is why this is a read-and-cache,
# never a write.
#
# The snapshot stores the account's ENTIRE capabilities hash, not just the capabilities we
# consult today. The mapping from payment method type to required capability happens at read
# time, so launching a new payment method later (SEPA, iDEAL, Klarna, ...) only needs a new
# entry in CAPABILITY_BY_PAYMENT_METHOD_TYPE — every existing snapshot already carries the
# answer, with no re-fetch or invalidation sweep.
class StripeConnectPaymentMethodAvailabilityService
  # Maps a payment method type (as used in PaymentIntent payment_method_types) to the Stripe
  # Account capability that must be "active" for the account to accept it. Extend this map
  # when a new method launches on the client-confirm path; the cached snapshots already hold
  # the full capabilities hash. Capability names per
  # https://docs.stripe.com/api/accounts/object#account_object-capabilities
  CAPABILITY_BY_PAYMENT_METHOD_TYPE = {
    "cashapp" => "cashapp_payments",
    "us_bank_account" => "us_bank_account_ach_payments",
    "link" => "link_payments",
    "klarna" => "klarna_payments",
    "afterpay_clearpay" => "afterpay_clearpay_payments",
    "affirm" => "affirm_payments",
    "ideal" => "ideal_payments",
    "bancontact" => "bancontact_payments",
    "sepa_debit" => "sepa_debit_payments",
  }.freeze

  def initialize(merchant_account)
    @merchant_account = merchant_account
  end

  # How long a snapshot is trusted before checkout resolution asks for a background re-fetch.
  # The webhooks are the primary freshness mechanism; this is the self-heal for the events they
  # can drop — sidekiq's until_executed lock discards an enqueue that lands while a refresh for
  # the same account is already MID-EXECUTION, so a capability deactivated in that window would
  # otherwise stay "active" in the snapshot forever (re-listing a method the account no longer
  # accepts — gumroad-private#1026's failure). A stale snapshot is still USED (checkout never
  # blocks); it just also triggers a refresh so the staleness is bounded.
  SNAPSHOT_MAX_AGE = 24.hours

  def snapshot_stale?
    snapshot = merchant_account.stripe_capabilities_snapshot
    return false if snapshot.nil?

    refreshed_at = begin
      Time.zone.parse(snapshot["refreshed_at"].to_s)
    rescue ArgumentError
      nil
    end
    refreshed_at.nil? || refreshed_at < SNAPSHOT_MAX_AGE.ago
  end

  # Fetches the account's full capabilities hash from Stripe and persists it. Returns the
  # capabilities hash. Raises on Stripe/API errors — callers decide whether to retry (the
  # refresh worker) or fail safe (checkout resolution reads the cache only).
  def refresh!
    return {} unless merchant_account.is_a_stripe_connect_account?

    stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
    capabilities = (stripe_account.to_hash[:capabilities] || {}).transform_keys(&:to_s)

    merchant_account.with_lock do
      merchant_account.stripe_capabilities_snapshot = {
        "capabilities" => capabilities,
        "refreshed_at" => Time.current.iso8601,
      }
      merchant_account.save!
    end
    capabilities
  end

  # Filters the given payment method types down to the ones the cached snapshot says the
  # account accepts. Returns nil when no snapshot has been taken yet — the caller decides the
  # fail-safe. A method type with no entry in CAPABILITY_BY_PAYMENT_METHOD_TYPE is treated as
  # unavailable (fail closed) rather than passed through: an unmapped method on a connect
  # account is exactly the intent-create rejection this cache exists to prevent. Never calls
  # Stripe — checkout resolution must not block on (or fail with) a Stripe API call.
  def available_payment_method_types(payment_method_types)
    snapshot = merchant_account.stripe_capabilities_snapshot
    return nil if snapshot.nil?

    capabilities = snapshot["capabilities"] || {}
    payment_method_types.select do |method_type|
      capability = CAPABILITY_BY_PAYMENT_METHOD_TYPE[method_type]
      capability.present? && capabilities[capability] == "active"
    end
  end

  def cache_present?
    !merchant_account.stripe_capabilities_snapshot.nil?
  end

  private
    attr_reader :merchant_account
end
