# frozen_string_literal: true

# Lifts our own platform's charges pause (`risk_controls.charges.pause_requested`) from a seller's
# Gumroad-managed Stripe account after they are marked compliant (gumroad-private#3221).
#
# Nothing else clears it. While it stays set, Stripe leaves `capabilities.transfers` inactive, every
# payout's funding transfer fails, and Payment#pause_payouts_after_repeated_failures then pauses
# payouts, so the seller looks "under review again" with the money still with us.
#
# Only the plain case is lifted: charges paused, payouts not paused, reason `platform_paused`, nothing
# past due. Anything else (both paused, a `rejected.*` reason, outstanding KYC) may be a deliberate
# hold or a real Stripe decision, so it is left alone and noted on the user instead.
class LiftPlatformStripePauseJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 3, lock: :until_executed

  AUTHOR_NAME = "platform-stripe-pause-lift"

  def perform(user_id)
    user = User.find_by(id: user_id)
    # Re-flagged between the transition and this run: the pause is no longer ours to lift.
    return if user.nil? || !user.compliant?

    user.merchant_accounts.alive.charge_processor_alive.stripe.each do |merchant_account|
      next unless merchant_account.is_a_gumroad_managed_stripe_account?

      lift_pause(user, merchant_account.charge_processor_merchant_id)
    end
  end

  private
    def lift_pause(user, stripe_account_id)
      account = Stripe::Account.retrieve(stripe_account_id)
      before = state_of(account)
      # No platform pause on this account, which is the usual case for a compliant seller. A note
      # on every transition would bury the ones that matter.
      return unless before[:charges_paused] || before[:disabled_reason] == "platform_paused"

      reason_to_skip = reason_to_skip(before)
      if reason_to_skip
        add_note(user, "Left the platform Stripe pause on #{stripe_account_id}: #{reason_to_skip}. Before: #{describe(before)}.")
        return
      end

      updated = Stripe::Account.update(stripe_account_id, risk_controls: { charges: { pause_requested: false } })
      add_note(user, "Lifted the platform Stripe pause on #{stripe_account_id} after the account was marked compliant. " \
                     "Before: #{describe(before)}. After: #{describe(state_of(updated))}.")
    rescue Stripe::InvalidRequestError, Stripe::PermissionError => e
      # Retrying cannot fix a missing or inaccessible account, so record it and move on to the next one.
      add_note(user, "Could not lift the platform Stripe pause on #{stripe_account_id}: #{e.message}")
    end

    def reason_to_skip(state)
      return "payouts are paused too, or their state is unknown, so the hold may be deliberate" unless state[:payouts_paused] == false
      return "the charges pause is not set" unless state[:charges_paused]
      return "the account is disabled for #{state[:disabled_reason].inspect}, not platform_paused" unless state[:disabled_reason] == "platform_paused"
      "Stripe still lists past-due requirements" if state[:past_due]
    end

    # `Stripe::StripeObject` exposes `[]` but not `dig`.
    def state_of(account)
      risk_controls = account["risk_controls"]
      requirements = account["requirements"]
      future_requirements = account["future_requirements"]
      {
        charges_paused: risk_controls && risk_controls["charges"] && risk_controls["charges"]["pause_requested"],
        payouts_paused: risk_controls && risk_controls["payouts"] && risk_controls["payouts"]["pause_requested"],
        disabled_reason: requirements && requirements["disabled_reason"],
        past_due: (requirements && requirements["past_due"]).present? || (future_requirements && future_requirements["past_due"]).present?,
        transfers: account["capabilities"] && account["capabilities"]["transfers"],
      }
    end

    def describe(state)
      "charges paused: #{state[:charges_paused].inspect}, payouts paused: #{state[:payouts_paused].inspect}, " \
        "disabled reason: #{state[:disabled_reason].inspect}, past due: #{state[:past_due]}, transfers: #{state[:transfers].inspect}"
    end

    def add_note(user, content)
      user.comments.create!(author_name: AUTHOR_NAME, comment_type: Comment::COMMENT_TYPE_NOTE, content:)
    end
end
