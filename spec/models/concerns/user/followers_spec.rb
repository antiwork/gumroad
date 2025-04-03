# frozen_string_literal: true

require "spec_helper"

describe User::Followers do
  describe "#following" do
    let(:following_user) { create(:user, email: "follower@example.com") }
    let(:not_following_user) { create(:user) }
    let(:creator_one) { create(:user) }
    let(:creator_two) { create(:user) }
    let!(:following_relationship_one) { create(:active_follower, user: creator_one, email: "follower@example.com") }
    let!(:following_relationship_two) { create(:active_follower, user: creator_one, email: "different@example.com", follower_user_id: following_user.id) }
    let!(:following_relationship_three) { create(:deleted_follower, email: "follower@example.com") }
    let!(:following_relationship_four) { create(:active_follower, user: creator_two, email: "follower@example.com") }
    let!(:following_relationship_five) { create(:active_follower, user: following_user, email: "follower@example.com") }

    it "returns users being followed" do
      expect(following_user.following).to match_array([
                                                        { external_id: following_relationship_one.external_id, creator: creator_one },
                                                        { external_id: following_relationship_four.external_id, creator: creator_two },
                                                      ])
      expect(not_following_user.following).to match_array([])
    end
  end

  describe "#follower_by_email" do
    it "returns the active follower matching the provided email" do
      user = create(:user)

      active_follower = create(:active_follower, user:)
      expect(user.follower_by_email(active_follower.email)).to eq(active_follower)

      unconfirmed_follower = create(:follower, user:)
      expect(user.follower_by_email(unconfirmed_follower.email)).to eq(nil)

      deleted_follower = create(:deleted_follower, user:)
      expect(user.follower_by_email(deleted_follower.email)).to eq(nil)
    end
  end

  describe "#followed_by?" do
    it "returns true if user has confirmed follower with that email" do
      user = create(:user)
      active_follower = create(:active_follower, user:)
      expect(user.followed_by?(active_follower.email)).to eq(true)
      unconfirmed_follower = create(:follower, user:)
      expect(user.followed_by?(unconfirmed_follower.email)).to eq(false)
      deleted_follower = create(:deleted_follower, user:)
      expect(user.followed_by?(deleted_follower.email)).to eq(false)
    end
  end

  describe "#add_follower" do
    let(:followed_user) { create(:user) }
    let(:follower_email) { "follower@example.com" }
    let(:logged_in_user) { create(:user, email: follower_email) }
    let(:follow_source) { "welcome-greeter" }

    it "calls Follower::CreateService and returns the follower object" do
      expect(Follower::CreateService).to receive(:perform).with(
        followed_user:,
        follower_email:,
        follower_attributes: { source: follow_source },
        logged_in_user:
      ).and_call_original
      follower = followed_user.add_follower(follower_email, source: follow_source, logged_in_user:)
      expect(follower).to be_kind_of(Follower)
    end

    it "updates source when the user is already following the same creator using the same email" do
      follower = create(:active_follower, user: followed_user, email: follower_email, follower_user_id: logged_in_user.id, source: Follower::From::FOLLOW_PAGE)

      expect do
        followed_user.add_follower(follower_email, source: Follower::From::CSV_IMPORT)
      end.to change { follower.reload.source }.from(Follower::From::FOLLOW_PAGE).to(Follower::From::CSV_IMPORT)
    end
  end
end
