# frozen_string_literal: true

# Converges one buyer's audience_members row after a LockWaitTimeout aborted an
# incremental update (see Purchase::AudienceMember#add_to_audience_member_details).
# refresh! rebuilds from live purchase/follower/affiliate state, so running it once
# the contending writers finish is correct regardless of which update lost.
class RefreshAudienceMemberJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed, on_conflict: :replace

  def perform(email, seller_id)
    AudienceMember.find_or_initialize_by(email:, seller_id:).refresh!
  end
end
