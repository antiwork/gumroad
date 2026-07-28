# frozen_string_literal: true

# Re-checks one seller who is under an automatic chargeback-rate payout hold, and lifts the hold if
# their rate is back within the allowed range.
#
# The release deliberately mirrors the pause: same rate (the lifetime unrefunded-sales volume ratio
# from User#lost_chargebacks), same threshold constant, and an audit comment on the account so the
# release is as traceable as the pause was.
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
    return if user.suspended? || user.flagged?
    return unless user.payouts_paused_for_chargeback_rate?

    volume_percentage = user.lost_chargebacks[:volume]
    # "NA" means the seller has no settled sales volume to divide by, so there is no rate to
    # compare. Leave the hold in place rather than guessing.
    return if volume_percentage == "NA"
    return if volume_percentage.to_f > User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS

    User.transaction do
      user.update!(payouts_paused_internally: false, payouts_paused_by: nil)
      user.comments.create!(
        content: "Payouts automatically resumed: chargeback rate (#{volume_percentage}) is back within " \
                 "the #{User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS}% volume limit.",
        comment_type: Comment::COMMENT_TYPE_PAYOUTS_RESUMED,
        author_name: User::CHARGEBACK_RATE_PAYOUT_RESUME_COMMENT_AUTHOR
      )
    end
  end
end
