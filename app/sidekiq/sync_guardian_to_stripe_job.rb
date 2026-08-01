# frozen_string_literal: true

# Sends a seller's legal guardian to Stripe after they add or edit one in payout settings.
#
# Every other write of the guardian's Stripe Person hangs off a compliance revision being created,
# which is exactly what attaching a guardian deliberately does NOT do — guardian_id is mutable on the
# live revision so adding one does not republish the seller's own details. Without this job the
# seller fills the form in, every surface tells them they are done, and Stripe never learns the
# guardian exists, so the requirement that stopped their payouts stays unmet.
#
# Idempotent: StripeGuardianManager.sync re-reads the guardian under its own per-account lock and
# updates the Person it already recorded rather than creating a second one.
class SyncGuardianToStripeJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id)
    user = User.find(user_id)

    # A seller paid through their own connected Stripe account has no Gumroad-managed account for a
    # guardian to go on, and Stripe verifies them under their own agreement. Reads the payout gate's
    # own predicate, not the broader has_stripe_account_connected?, so this job syncs for exactly the
    # sellers the settings page asks and the guardian endpoint accepts: a Brazilian connected account
    # is not exempt anywhere in that set, and skipping it here would leave a guardian the seller was
    # told was complete never sent to the managed account Stripe is actually verifying.
    return if StripePayoutProcessor.pays_user_via_stripe_connect?(user)

    merchant_account = user.stripe_account
    return if merchant_account.nil?

    stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
    StripeGuardianManager.sync(user, stripe_account, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
  end
end
