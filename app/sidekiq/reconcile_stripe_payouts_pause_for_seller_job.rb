# frozen_string_literal: true

# Resumes a Stripe-source payout pause when Stripe now reports payouts enabled: the missed-webhook
# self-heal for `account.updated`, sharing its resume writer so whichever runs second is a no-op.
#
# Suspended, flagged and deleted accounts are skipped, and so is a seller with an unaccounted payout
# hold: Stripe re-enabling payouts is not a reason to undo a risk decision.
class ReconcileStripePayoutsPauseForSellerJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed, retry: 2

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if user.nil?
    return unless stripe_paused?(user)

    # user.stripe_account is the canonical Gumroad-managed account (alive and charge-processor
    # alive); a connect account is the seller's own and never carries our pause state.
    merchant_account = user.stripe_account
    return if merchant_account.nil?
    return if merchant_account.charge_processor_merchant_id.blank?

    # Must be read before the Stripe call. A lagging replica can only make it older, which skips the resume.
    disabled_observation_token = merchant_account.stripe_payouts_disabled_observation_token
    stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
    return unless stripe_account["payouts_enabled"]

    # The webhook rotates the token under this lock on every disabled report, including every Stripe
    # re-pause. A changed token or account means the enabled read may be stale; the next run re-reads.
    user.with_lock do
      next unless stripe_paused?(user)

      current_account = user.stripe_account
      next unless current_account == merchant_account
      next unless current_account.stripe_payouts_disabled_observation_token == disabled_observation_token

      StripeMerchantAccountManager.resume_stripe_payouts_pause!(user:, merchant_account: current_account)
    end
  end

  private
    def stripe_paused?(user)
      return false if user.suspended? || user.flagged? || user.deleted?
      return false unless user.payouts_paused_internally? && user.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_STRIPE

      !unaccounted_money_hold?(user)
    end

    # That hold only adds a comment when the seller is already paused, so the source still reads Stripe
    # while a person has to reconcile the money at Stripe. Same check as LiftPlatformStripePauseJob.
    def unaccounted_money_hold?(user)
      last_resumed_at = user.comments.with_type_payouts_resumed.maximum(:created_at)
      comments = user.comments.with_type_on_probation
                     .where(author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:repeated_failed_payouts])
                     .where("content LIKE ?", "%#{StripePayoutProcessor::UNACCOUNTED_MONEY_HOLD_MARKER}%")
      comments = comments.where("created_at >= ?", last_resumed_at) if last_resumed_at
      comments.exists?
    end
end
