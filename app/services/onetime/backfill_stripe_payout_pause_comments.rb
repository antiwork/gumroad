# frozen_string_literal: true

module Onetime
  class BackfillStripePayoutPauseComments
    BATCH_SIZE = 500
    COMMENT_AUTHOR_NAME = "Stripe payouts sync"

    def self.process(batch_size: BATCH_SIZE)
      new.process(batch_size:)
    end

    def process(batch_size: BATCH_SIZE)
      scope = MerchantAccount.stripe
        .charge_processor_alive
        .where.not(charge_processor_merchant_id: nil)

      scope.in_batches(of: batch_size) do |batch|
        ReplicaLagWatcher.watch
        batch.includes(:user).each { |merchant_account| backfill_comment(merchant_account) }
      end
    end

    private
      def backfill_comment(merchant_account)
        return if merchant_account.is_a_stripe_connect_account?

        user = merchant_account.user
        return if user.nil?
        # Cheap flag checks first; the canonical-account query only runs for the
        # small set of Stripe-paused users (vs. every alive Stripe account).
        return unless user.payouts_paused? && user.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_STRIPE
        return unless merchant_account == user.stripe_account

        comment = merchant_account.stripe_payouts_paused_comment
        return if user.comments.with_type_payouts_paused.last&.content == comment

        user.comments.create!(
          author_name: COMMENT_AUTHOR_NAME,
          comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED,
          content: comment
        )
        puts "Backfilled payout pause comment for User #{user.id} → #{merchant_account.stripe_disabled_reason.inspect}"
      end
  end
end
