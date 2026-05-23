# frozen_string_literal: true

require "test_helper"

class WishlistFollowerTest < ActiveSupport::TestCase
  self.described_class = WishlistFollower



  context_ WishlistFollower do
  context_ "validations" do
  test "validates uniqueness of follower" do
        wishlist = create(:wishlist)
        user = create(:buyer_user)
        first_follower = create(:wishlist_follower, wishlist:, follower_user: user)

        second_follower = build(:wishlist_follower, wishlist:, follower_user: user)
        expect(second_follower).not_to be_valid
        expect(second_follower.errors.full_messages.sole).to eq("Follower user is already following this wishlist.")

        second_follower.wishlist = create(:wishlist)
        expect(second_follower).to be_valid

        second_follower.wishlist = wishlist
        first_follower.mark_deleted!
        expect(second_follower).to be_valid
      end

  test "prevents a user from following their own wishlist" do
        wishlist = create(:wishlist)
        wishlist_follower = build(:wishlist_follower, wishlist:, follower_user: wishlist.user)
        expect(wishlist_follower).not_to be_valid
        expect(wishlist_follower.errors.full_messages.sole).to eq("You cannot follow your own wishlist.")
      end
    end
  end
end
