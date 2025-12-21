# frozen_string_literal: true

class SendMissedPostsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  def perform(purchase_id, workflow_id = nil)
    purchase = Purchase.find_by_external_id!(purchase_id)

    CustomersService.deliver_missed_posts_for!(purchase:, workflow_id:)

    CustomersChannel.broadcast_missed_posts_message!(
      purchase.external_id,
      workflow_id,
      CustomersChannel::MISSED_POSTS_JOB_COMPLETE_TYPE
    )
  end

  RetryHandler = ->(count, exception, msg) do
    case exception
    when CustomersService::CustomerDNDEnabledError
      Rails.logger.info("[SendMissedPostsJob] Discarding job on #{(count + 1).ordinalize} attempt for purchase with DND enabled: #{exception.message}")
      :discard
    when CustomersService::SellerNotEligibleError
      Rails.logger.info("[SendMissedPostsJob] Discarding job on #{(count + 1).ordinalize} attempt for ineligible seller: #{exception.message}")
      :discard
    end
  end

  FailureHandler = ->(job, exception) do
    purchase_id, workflow_id = job["args"]

    CustomersChannel.broadcast_missed_posts_message!(
      purchase_id,
      workflow_id,
      CustomersChannel::MISSED_POSTS_JOB_FAILED_TYPE
    )
  end

  sidekiq_retry_in(&RetryHandler)

  sidekiq_retries_exhausted(&FailureHandler)
end
