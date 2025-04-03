# frozen_string_literal: true

class RecalculateRecentWishlistFollowerCountJob
  include Sidekiq::Job

  def perform
    Wishlist.find_in_batches do |batch|
      follower_counts = WishlistFollower.alive
        .where(wishlist_id: batch.map(&:id))
        .where("created_at > ?", 30.days.ago)
        .group(:wishlist_id)
        .count

      batch.each do |wishlist|
        wishlist.update!(recent_follower_count: follower_counts[wishlist.id] || 0)
      end
    end
  end
end
