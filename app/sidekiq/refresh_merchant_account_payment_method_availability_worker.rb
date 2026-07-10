# frozen_string_literal: true

# Refreshes the cached Stripe capabilities snapshot for a Stripe Connect (direct-charge)
# seller's MerchantAccount. Enqueued from three places:
#   1. Stripe account.updated / capability.updated webhooks — the seller (de)activated a
#      payment method in their own Stripe dashboard.
#   2. Checkout resolution (Checkout::PaymentMethodResolver) when a connect seller has no
#      snapshot yet — the lazy backfill. That checkout fails safe (offers none of the
#      US-locked methods); the NEXT checkout benefits from the fetched snapshot.
#   3. Any manual/console backfill sweep.
# lock: :until_executed dedupes the bursts these sources produce (Stripe sends several
# account.updated events in a row; every checkout on an uncached seller enqueues one).
class RefreshMerchantAccountPaymentMethodAvailabilityWorker
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3, lock: :until_executed

  def perform(merchant_account_id)
    merchant_account = MerchantAccount.find(merchant_account_id)
    return unless merchant_account.alive? && merchant_account.charge_processor_alive?
    return unless merchant_account.is_a_stripe_connect_account?

    StripeConnectPaymentMethodAvailabilityService.new(merchant_account).refresh!
  rescue Stripe::PermissionError, Stripe::AuthenticationError
    # The account revoked platform access (deauthorized between enqueue and execution).
    # There is nothing to refresh; deauthorization handling elsewhere will bury the record.
  rescue Stripe::InvalidRequestError => e
    # Stripe-side-deleted account (raced ahead of our deauth webhook processing): same story —
    # nothing to refresh, retrying can't succeed. Anything else is a real error; let it retry.
    raise unless e.message.to_s.match?(/does not exist/i)
  end
end
