# frozen_string_literal: true

class CheckMissedPostsCompletionJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :low

  MAX_ATTEMPTS = 4
  CHECK_INTERVAL = 5.minutes

  def perform(purchase_id, workflow_id = nil, attempt = 1)
    purchase = Purchase.find(purchase_id)

    missed_posts = Installment.missed_for_purchase(purchase)
    missed_posts = missed_posts.where(workflow_id:) if workflow_id.present?

    if missed_posts.empty? || attempt >= MAX_ATTEMPTS
      $redis.del(RedisKey.send_missed_posts(purchase.id))
    else
      CheckMissedPostsCompletionJob.perform_in(CHECK_INTERVAL, purchase_id, workflow_id, attempt + 1)
    end
  end
end
