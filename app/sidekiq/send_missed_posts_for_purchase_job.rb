# frozen_string_literal: true

class SendMissedPostsForPurchaseJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low, lock: :until_executed

  THROTTLE_PERIOD = 8.hours

  def perform(purchase_id, workflow_id = nil)
    purchase = Purchase.find(purchase_id)
    return unless purchase.can_contact?

    seller = purchase.seller
    return unless seller.eligible_to_send_emails?

    missed_posts = Installment.missed_for_purchase(purchase).order(published_at: :desc)
    missed_posts = missed_posts.where(workflow_id:) if workflow_id.present?
    return if missed_posts.empty?

    missed_posts.each do |post|
      cache_key = "post_email:#{post.id}:#{purchase.id}"
      next if Rails.cache.exist?(cache_key)

      Rails.cache.fetch(cache_key, expires_in: THROTTLE_PERIOD) do
        CreatorContactingCustomersEmailInfo.destroy_by(purchase:, installment: post)

        PostEmailApi.process(
          post:,
          recipients: [
            {
              email: purchase.email,
              purchase:,
              url_redirect: purchase.url_redirect,
              subscription: purchase.subscription,
            }.compact_blank
          ])
        true
      end
    rescue StandardError => e
      Rails.logger.error("[SendMissedPostsForPurchaseJob] Failed to send post #{post.id} for purchase #{purchase_id}: #{e.class} - #{e.message}")
    end

    CheckMissedPostsCompletionJob.perform_in(2.minutes, purchase_id, workflow_id)
  end
end
