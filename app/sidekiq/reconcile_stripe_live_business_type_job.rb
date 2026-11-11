# frozen_string_literal: true

class ReconcileStripeLiveBusinessTypeJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 2, lock: :until_executed

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user && StripeMerchantAccountManager.live_business_type_reconcilable?(user)

    stripe_account = Stripe::Account.retrieve(user.stripe_account.charge_processor_merchant_id)
    return unless StripeMerchantAccountManager::LIVE_NON_INDIVIDUAL_BUSINESS_TYPES.include?(stripe_account["business_type"])

    # The reconcile reads the compliance record only after taking the lock, so a concurrent switch to business is seen.
    user.with_lock { StripeMerchantAccountManager.reconcile_live_business_type(user) }
  rescue Stripe::StripeError => e
    # The next Payments load re-queues this, so a retry would only repeat the failing read.
    ErrorNotifier.notify(e, context: { user_id: })
  end
end
