# frozen_string_literal: true

class WishlistFollower < ApplicationRecord
  include ExternalId
  include Deletable

  belongs_to :wishlist
  belongs_to :follower_user, class_name: "User"

  validates :follower_user, uniqueness: { scope: [:wishlist_id, :deleted_at], message: "is already following this wishlist." }
  validate :cannot_follow_own_wishlist

  after_create :increment_follower_count
  after_update :update_follower_count, if: :saved_change_to_deleted_at?

  private
    def cannot_follow_own_wishlist
      if follower_user_id.present? && follower_user_id == wishlist&.user_id
        errors.add(:base, "You cannot follow your own wishlist.")
      end
    end

    def increment_follower_count
      wishlist.increment!(:follower_count)
    end

    def update_follower_count
      if deleted_at.present?
        wishlist.decrement!(:follower_count)
      else
        wishlist.increment!(:follower_count)
      end
    end
end
