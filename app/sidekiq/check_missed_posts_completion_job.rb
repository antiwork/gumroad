# frozen_string_literal: true

class CheckMissedPostsCompletionJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :low

  INITIAL_INTERVAL = 2.minutes
  MAX_CHECKS = 4

  def perform(purchase_id, workflow_id = nil, check_number = 1)
    purchase = Purchase.find(purchase_id)
    remaining = MissedPostsDeliveryService.new(purchase:).missed_posts(workflow_id:)
    lock_suffix = workflow_id || "all"

    if remaining.empty? || check_number >= MAX_CHECKS
      $redis.del(RedisKey.send_missed_posts(purchase.id, lock_suffix))
    else
      delay = INITIAL_INTERVAL * (2**(check_number - 1))
      CheckMissedPostsCompletionJob.perform_in(delay, purchase_id, workflow_id, check_number + 1)
    end
  end
end
