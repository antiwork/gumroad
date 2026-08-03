# frozen_string_literal: true

# Re-checks one seller who is under an automatic chargeback-rate payout hold, and lifts the hold if
# their rate is back within the allowed range.
#
# The release deliberately mirrors the pause: same rate (the trailing-window unrefunded-sales volume
# ratio from User#lost_chargebacks_for_payout_gate), same threshold constant, same window, and an
# audit comment on the account so the release is as traceable as the pause was. Reading a different
# span than the pause would either re-pause the seller immediately or never fire at all.
#
# Accounts that are suspended or flagged are left alone. Those are risk decisions made about the
# account as a whole, and a recovered chargeback rate is not a reason to undo them — releasing there
# would be this job overruling a human.
class ReleaseChargebackRatePayoutPauseForSellerJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed, retry: 2

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if user.nil?
    return unless releasable?(user)

    volume_percentage = user.lost_chargebacks_for_payout_gate[:volume]
    # "NA" means the seller has no settled sales volume to divide by, so there is no rate to
    # compare. Leave the hold in place rather than guessing.
    return if volume_percentage == "NA"
    return if volume_percentage.to_f > User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS

    # The rate comes from an Elasticsearch aggregation, which can take long enough that an admin
    # pauses, suspends, or closes the account in between. Re-check every guard against a locked,
    # freshly-read row so this job can never clear a hold that was put there after it started.
    #
    # The lock also serializes against the two automatic pause writers: each sets the flag and
    # writes its identifying comment in one transaction, so this SELECT ... FOR UPDATE waits for
    # that transaction to commit and can never observe a hold whose comment has not landed yet.
    user.with_lock do
      next unless releasable?(user)

      user.update!(payouts_paused_internally: false, payouts_paused_by: nil)
      user.comments.create!(
        content: resume_comment_content(user, volume_percentage),
        comment_type: Comment::COMMENT_TYPE_PAYOUTS_RESUMED,
        author_name: User::CHARGEBACK_RATE_PAYOUT_RESUME_COMMENT_AUTHOR
      )
    end
  end

  private
    # A seller can pause their own payouts independently of this hold, in which case lifting the
    # hold does not actually start paying them. Say so rather than writing a flat "resumed" that
    # contradicts the account's real state — same shape the Stripe resume path uses.
    def resume_comment_content(user, volume_percentage)
      recovered = "chargeback rate (#{volume_percentage}) is back within the " \
                  "#{User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS}% volume limit over the last " \
                  "#{User::PAYOUT_CHARGEBACK_RATE_WINDOW.inspect}"

      if user.payouts_paused_by_user?
        "Automatic chargeback-rate hold lifted: #{recovered}. Payouts remain paused by the creator."
      else
        "Payouts automatically resumed: #{recovered}."
      end
    end

    # A closed or GDPR-erased account also gets payouts_paused_internally set, and neither path
    # clears payouts_paused_by — so an account that was chargeback-paused before it was closed
    # still looks chargeback-paused afterwards. Releasing there would re-open payouts on an
    # account that is supposed to stay shut, so deleted accounts are excluded outright.
    def releasable?(user)
      return false if user.suspended? || user.flagged?
      return false if user.deleted?

      user.payouts_paused_for_chargeback_rate?
    end
end
