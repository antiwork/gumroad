# frozen_string_literal: true

# When a user is suspended (fraud or TOS), remove the follows that account holds
# on other creators. A suspended account should not stay subscribed to creators'
# follower email lists — otherwise it keeps receiving (and replying to) email blasts.
#
# A follow can be linked to the account two ways: by `follower_user_id`, or — for
# follows created before the account existed / never backfilled — by email only
# (`follower_user_id` is nil but `followers.email == user.form_email`). The app's own
# `User#following` resolves outbound follows by email, so both paths must be covered.
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

    Follower.alive
            .where("follower_user_id = :id OR email = :email", id: user_id, email: user.form_email)
            .find_each(&:mark_deleted!)
  end
end
