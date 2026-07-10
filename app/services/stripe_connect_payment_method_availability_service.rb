# frozen_string_literal: true

# Fetches which US-locked payment methods (Cash App Pay, ACH Direct Debit) a Stripe Connect
# (direct-charge) seller's own Stripe account can accept, and caches the answer on the
# MerchantAccount record.
#
# Why this exists: charges for a direct-charge seller are created on the seller's Stripe
# account, not Gumroad's platform account, and payment method capabilities are per-account.
# Stripe rejects a PaymentIntent create outright when payment_method_types lists a method the
# account hasn't activated — which fails the whole checkout even when the buyer picked a plain
# card (see gumroad-private#1026). So checkout must only offer these methods on accounts that
# actually have them. Standard Connect accounts manage their own capabilities (the platform
# cannot request capabilities on the seller's behalf), which is why this is a read-and-cache,
# never a write.
class StripeConnectPaymentMethodAvailabilityService
  # Maps each US-locked payment method type (as used in PaymentIntent payment_method_types)
  # to the Stripe Account capability that must be "active" for the account to accept it.
  CAPABILITY_BY_PAYMENT_METHOD_TYPE = {
    "cashapp" => "cashapp_payments",
    "us_bank_account" => "us_bank_account_ach_payments",
  }.freeze

  def initialize(merchant_account)
    @merchant_account = merchant_account
  end

  # Fetches the account's capabilities from Stripe and persists the snapshot. Returns the
  # available payment method types. Raises on Stripe/API errors — callers decide whether to
  # retry (the refresh worker) or fail safe (checkout resolution reads the cache only).
  def refresh!
    return [] unless merchant_account.is_a_stripe_connect_account?

    stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
    capabilities = stripe_account.to_hash[:capabilities] || {}
    available = CAPABILITY_BY_PAYMENT_METHOD_TYPE.select { |_, capability| capabilities[capability.to_sym] == "active" }.keys

    merchant_account.with_lock do
      merchant_account.us_locked_payment_method_availability = {
        "payment_method_types" => available,
        "refreshed_at" => Time.current.iso8601,
      }
      merchant_account.save!
    end
    available
  end

  # The cached available method types, or nil when no snapshot has been taken yet. Never
  # calls Stripe — checkout resolution must not block on (or fail with) a Stripe API call.
  def cached_payment_method_types
    snapshot = merchant_account.us_locked_payment_method_availability
    return nil if snapshot.nil?

    Array(snapshot["payment_method_types"]) & CAPABILITY_BY_PAYMENT_METHOD_TYPE.keys
  end

  def cache_present?
    !merchant_account.us_locked_payment_method_availability.nil?
  end

  private
    attr_reader :merchant_account
end
