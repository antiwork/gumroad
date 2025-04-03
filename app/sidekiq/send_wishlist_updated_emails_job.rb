# frozen_string_literal: true

class SendWishlistUpdatedEmailsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(wishlist_id, wishlist_product_ids)
    wishlist = Wishlist.find(wishlist_id)
    wishlist_products = wishlist.wishlist_products.alive.where(id: wishlist_product_ids)
    return if wishlist_products.empty?

    last_product_added_at = wishlist_products.maximum(:created_at)
    return if wishlist.wishlist_products_for_email.where("created_at > ?", last_product_added_at).exists?

    wishlist.wishlist_followers.find_each do |wishlist_follower|
      SentEmailInfo.ensure_mailer_uniqueness("CustomerLowPriorityMailer",
                                             "wishlist_updated",
                                             wishlist_follower.id, wishlist_product_ids) do
        new_products = wishlist_products.select { _1.created_at > wishlist_follower.created_at }
        if new_products.any?
          CustomerLowPriorityMailer.wishlist_updated(wishlist_follower.id, new_products.size).deliver_later(queue: "low")
        end
      end
    end

    wishlist.update!(followers_last_contacted_at: last_product_added_at)
  end
end
