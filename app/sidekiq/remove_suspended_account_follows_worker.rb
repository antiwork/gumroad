# frozen_string_literal: true

# When a user is suspended (fraud or TOS), remove the follows that account has on
# other creators. A suspended account should not stay subscribed to creators'
# follower email lists — otherwise it keeps receiving (and replying to) email blasts.
#
# `Follower#mark_deleted!` soft-deletes the row AND clears `confirmed_at`, which drops
# the follower from the creator's email audience. Idempotent: rows already deleted are
# skipped, so retries and re-suspensions are safe.
class RemoveSuspendedAccountFollowsWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(user_id)
    user = User.find(user_id)
    return unless user.suspended?

    Follower.alive.where(follower_user_id: user_id).find_each(&:mark_deleted!)
  end
end
