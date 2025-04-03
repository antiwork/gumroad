# frozen_string_literal: true

require "spec_helper"

describe RecalculateRecentWishlistFollowerCountJob do
  describe "#perform" do
    let!(:wishlist1) { create(:wishlist) }
    let!(:wishlist2) { create(:wishlist) }

    before do
      create_list(:wishlist_follower, 3, wishlist: wishlist1, created_at: 15.days.ago)
      create_list(:wishlist_follower, 1, wishlist: wishlist2, created_at: 20.days.ago)
    end

    it "updates recent_follower_count for all wishlists" do
      expect do
        described_class.new.perform
      end.to change { wishlist1.reload.recent_follower_count }.from(0).to(3)
        .and change { wishlist2.reload.recent_follower_count }.from(0).to(1)
    end

    it "only counts followers created within the last 30 days" do
      create_list(:wishlist_follower, 2, wishlist: wishlist1, created_at: 35.days.ago)
      create_list(:wishlist_follower, 4, wishlist: wishlist2, created_at: 40.days.ago)

      described_class.new.perform
      expect(wishlist1.reload.recent_follower_count).to eq(3)
      expect(wishlist2.reload.recent_follower_count).to eq(1)
    end

    it "handles wishlists with no recent followers" do
      wishlist3 = create(:wishlist)
      create_list(:wishlist_follower, 2, wishlist: wishlist3, created_at: 31.days.ago)

      described_class.new.perform
      expect(wishlist3.reload.recent_follower_count).to eq(0)
    end
  end
end
