# frozen_string_literal: true

class LinkStagedRailCardJob
  include Sidekiq::Job
  # Six retries back off past Provision::ATTEMPT_LEASE, so a link whose worker died holding the
  # lease is still picked up once the lease expires.
  sidekiq_options queue: :low, retry: 6, lock: :until_executed

  class RetryLater < StandardError; end

  def perform(setup_id)
    setup = StripePayoutRailSetup.find_by(id: setup_id)
    return if setup.nil?

    result = StripePayoutRailSetups::LinkStagedCard.new(setup).process
    # Raise so Sidekiq retries: the until_executed lock is still held here, so enqueueing this job
    # again from inside it would be dropped.
    raise RetryLater, "Card link for rail setup #{setup_id}: #{result}" if StripePayoutRailSetups::LinkStagedCard::RETRY_RESULTS.include?(result)
  end
end
