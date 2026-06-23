# frozen_string_literal: true

# When a user is suspended (fraud or TOS), remove the follows that account holds
# on other creators. A suspended account should not stay subscribed to creators'
# follower email lists — otherwise it keeps receiving (and replying to) email blasts.
#
# `Follower#mark_deleted!` soft-deletes the row AND clears `confirmed_at`, which drops
# the follower from the creator's email audience. Idempotent: rows already deleted are
# skipped, so retries and re-suspensions are safe.
class RemoveSuspendedAccountFollowsWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user&.suspended?

    # Follows linked directly to the account.
    Follower.alive.where(follower_user_id: user_id).find_each(&:mark_deleted!)

    # Email-only follows (created before the account existed / never backfilled): matched by
    # email and scoped to `follower_user_id IS NULL`, so a row linked to a DIFFERENT account
    # that shares a stale email is never collateral. Keyed ONLY off the verified confirmed
    # email — never `unconfirmed_email`, which a suspended account could point at a victim's
    # address to unsubscribe that victim's follows. Skipped when the account has no email, so
    # a nil email never matches (and soft-deletes) every null-email follower row.
    return if user.email.blank?

    Follower.alive.where(follower_user_id: nil, email: user.email).find_each(&:mark_deleted!)
  end
end
