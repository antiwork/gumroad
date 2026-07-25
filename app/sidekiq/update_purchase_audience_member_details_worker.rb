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
class UpdatePurchaseAudienceMemberDetailsWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(purchase_id)
    purchase = Purchase.find_by(id: purchase_id)
    # The purchase can be gone by the time this runs (hard-deleted test data, for example);
    # there is then no audience document left to refresh.
    return if purchase.nil?

    purchase.add_to_audience_member_details
  end
end
