# frozen_string_literal: true

# Converges one buyer's audience_members row out of band. Purchase changes schedule this
# instead of writing the projection inline (see Purchase::AudienceMember); follower and
# affiliate callbacks fall back to it when their incremental update hits a LockWaitTimeout.
# refresh! rebuilds from live purchase/follower/affiliate state, so running it once the
# contending writers finish is correct regardless of which update lost.
class RefreshAudienceMemberJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed, on_conflict: :replace

  def perform(email, seller_id)
    AudienceMember.find_or_initialize_by(email:, seller_id:).refresh!
  end
end
