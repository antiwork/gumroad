# frozen_string_literal: true

# Refreshes a buyer's AudienceMember document for one purchase, outside the web request.
#
# `audience_members.details` is a single JSON column that holds every purchase for an
# (email, seller) pair, so rewriting it takes a write lock on that row for as long as the
# rewrite runs. Doing that inline while a public API request is in flight means two
# concurrent requests for the same buyer serialize on one row, and the losers wait until
# MySQL's lock wait timeout fires and then return a 500 to the caller. Nothing in those
# responses depends on the audience data, so the write belongs here where Sidekiq's retries
# absorb a lock timeout instead of the buyer's software seeing a failed request.
#
# `lock: :until_executed` is what actually keeps a burst cheap. A client verifying the same
# license repeatedly would otherwise enqueue one job per call, and every one of them would
# redo the same full rewrite of the same row — moving the pile-up into Sidekiq rather than
# removing it. Deduplicating on purchase_id is safe because the job derives everything it
# writes from current database state, so one run covers any number of collapsed calls.
class UpdatePurchaseAudienceMemberDetailsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(purchase_id)
    # Deliberately `find`, not `find_by`: purchases are soft-deleted, so a row that is
    # genuinely missing means we are reading a lagging replica (or there is a bug). Letting
    # RecordNotFound raise hands it to the retries above, which is how the row gets picked up
    # once the replica catches up. Swallowing it would silently drop the audience update.
    Purchase.find(purchase_id).add_to_audience_member_details
  end
end
