# frozen_string_literal: true

# Recomputes an affiliate's lifetime earnings outside of a web request and
# stores it in the cache, so the affiliated products page never has to run that
# aggregate while someone is waiting for the page. See AffiliateEarningsCache.
#
# `lock: :until_executed` keeps an affiliate who reloads the page repeatedly
# (which is what people do when a page is slow) from queueing the same expensive
# sum many times over. That lock only collapses jobs that are still queued
# though, so the job also re-checks the cache before recomputing: if another run
# has already produced a fresh value there is nothing left to do, and skipping
# is what stops two unbounded scans of the same purchase history from running at
# once.
class RefreshAffiliateEarningsJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low, lock: :until_executed

  def perform(affiliate_id)
    affiliate = Affiliate.find_by(id: affiliate_id)
    return if affiliate.nil?

    AffiliateEarningsCache.refresh_unless_fresh!(affiliate)
  end
end
