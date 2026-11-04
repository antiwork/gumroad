# frozen_string_literal: true

# Resumes a Stripe-source payout pause when Stripe now reports payouts enabled: the missed-webhook
# self-heal for `account.updated`, sharing its resume writer so whichever runs second is a no-op.
#
# Suspended, flagged and deleted accounts are skipped: Stripe re-enabling payouts is not a reason to
# undo a risk decision.
class ReconcileStripePayoutsPauseForSellerJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed, retry: 2

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if user.nil?
    return unless stripe_paused?(user)

    # The pause this decision is based on. Every Stripe-source pause writes one of these comments,
    # and the reconciler only ever queues sellers that have one.
    pause_comment = latest_stripe_pause_comment(user)
    return if pause_comment.nil?

    # user.stripe_account is the canonical Gumroad-managed account (alive and charge-processor
    # alive); a connect account is the seller's own and never carries our pause state.
    merchant_account = user.stripe_account
    return if merchant_account.nil?
    return if merchant_account.charge_processor_merchant_id.blank?

    stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
    return unless stripe_account["payouts_enabled"]

    # Re-check under the lock: the webhook or an admin may have cleared or replaced the pause while
    # the Stripe call was in flight, and this must never undo a pause that was written after the
    # account was read. A fresh pause comment means Stripe disabled payouts again in that window and
    # that newer delivery wins; the next run picks it up.
    user.with_lock do
      next unless stripe_paused?(user)
      next unless latest_stripe_pause_comment(user)&.id == pause_comment.id

      merchant_account.reload
      StripeMerchantAccountManager.resume_stripe_payouts_pause!(user:, merchant_account:)
    end
  end

  private
    def stripe_paused?(user)
      return false if user.suspended? || user.flagged? || user.deleted?

      user.payouts_paused_internally? && user.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_STRIPE
    end

    def latest_stripe_pause_comment(user)
      user.comments
          .with_type_payouts_paused
          .where(author_name: StripeMerchantAccountManager::STRIPE_PAYOUTS_SYNC_COMMENT_AUTHOR)
          .order(:created_at, :id)
          .last
    end
end
