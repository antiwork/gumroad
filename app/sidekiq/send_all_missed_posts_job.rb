# frozen_string_literal: true

class SendAllMissedPostsJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3, lock: :until_executed

  def perform(seller_id, purchase_id)
    seller = User.find(seller_id)
    purchase = seller.sales.find(purchase_id)
    posts = Installment.missed_for_purchase(purchase)

    posts.find_each do |post|
      begin
        cache_key = "post_email:#{post.id}:#{purchase.id}"
        Rails.cache.fetch(cache_key, expires_in: 8.hours) do
          CreatorContactingCustomersEmailInfo.where(purchase:, installment: post).destroy_all

          PostEmailApi.process(
            post: post,
            recipients: [
              {
                email: purchase.email,
                purchase: purchase,
                url_redirect: purchase.url_redirect,
                subscription: purchase.subscription,
              }.compact_blank
            ])
          true
        end
      rescue => e
        Rails.logger.error "[SendAllMissedPostsJob] Failed to send post #{post.id} to purchase #{purchase.id}: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end
    end

    Rails.logger.info "[SendAllMissedPostsJob] Completed processing #{posts.count} missed posts for purchase #{purchase.id}"
  end
end
