# frozen_string_literal: true

class MissedPostsDeliveryService
  THROTTLE_PERIOD = 8.hours

  attr_reader :purchase

  def initialize(purchase:)
    @purchase = purchase
  end

  def deliver_all(workflow_id: nil)
    posts = missed_posts(workflow_id:)
    return if posts.empty?

    posts.each do |post|
      deliver_post(post)
    rescue StandardError => e
      Rails.logger.error("[MissedPostsDeliveryService] Failed to send post #{post.id} for purchase #{purchase.id}: #{e.class} - #{e.message}")
    end
  end

  def missed_posts(workflow_id: nil)
    posts = Installment.missed_for_purchase(purchase).order(published_at: :desc)
    posts = posts.where(workflow_id:) if workflow_id.present?
    posts
  end

  private
    def deliver_post(post)
      cache_key = "post_email:#{post.id}:#{purchase.id}"
      return if Rails.cache.exist?(cache_key)

      Rails.cache.fetch(cache_key, expires_in: THROTTLE_PERIOD) do
        CreatorContactingCustomersEmailInfo.destroy_by(purchase:, installment: post)
        PostEmailApi.process(
          post:,
          recipients: [{
            email: purchase.email,
            purchase:,
            url_redirect: purchase.url_redirect,
            subscription: purchase.subscription,
          }.compact_blank])
        true
      end
    end
end
