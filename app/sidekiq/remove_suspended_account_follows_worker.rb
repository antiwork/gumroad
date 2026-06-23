# frozen_string_literal: true

# When a user is suspended (fraud or TOS), remove the follows that account holds
# on other creators. A suspended account should not stay subscribed to creators'
# follower email lists — otherwise it keeps receiving (and replying to) email blasts.
#
# A follow can be linked to the account two ways: by `follower_user_id`, or — for
# follows created before the account existed / never backfilled — by email only
# (`follower_user_id` is nil but `followers.email` matches the account's confirmed
# email). The email-only match is scoped to `follower_user_id IS NULL` so a row
# explicitly linked to a DIFFERENT account that shares a stale email is never
# collateral, and uses ONLY the verified confirmed `email` (never `unconfirmed_email`,
# which an account can point at an address it hasn't proven it owns).
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

    # Only the VERIFIED confirmed email is used for the email-only fallback. We must not
    # key destructive cleanup off `unconfirmed_email` — a suspended account could set a
    # pending email to a victim's address and unsubscribe that victim's email-only follows.
    Follower.alive
            .where("follower_user_id = :id OR (follower_user_id IS NULL AND email = :email)", id: user_id, email: user.email)
            .find_each(&:mark_deleted!)
  end
end
