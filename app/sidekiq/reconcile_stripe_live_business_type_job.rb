# frozen_string_literal: true

# Payments page loads queue this so a business type flipped by a hosted Stripe form is caught even when the
# seller never returns through the form. The user lock keeps it from racing a switch to business.
class ReconcileStripeLiveBusinessTypeJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 2, lock: :until_executed

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if user.nil?

    # with_lock reloads the user, so the compliance record is read after the lock wait.
    user.with_lock { StripeMerchantAccountManager.reconcile_live_business_type(user) }
  end
end
