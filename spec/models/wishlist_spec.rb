# frozen_string_literal: true

require "spec_helper"

describe Wishlist do
  describe "#find_by_url_slug" do
    let(:wishlist) { create(:wishlist) }

    it "finds a wishlist" do
      expect(Wishlist.find_by_url_slug(wishlist.url_slug)).to eq(wishlist)
    end

    it "returns nil when the wishlist does not exist" do
      expect(Wishlist.find_by_url_slug("foo")).to be_nil
    end
  end

  describe "#url_slug" do
    let(:wishlist) { create(:wishlist, name: "My Wishlist") }

    it "returns a readable URL path plus the ID" do
      expect(wishlist.url_slug).to eq("my-wishlist-#{wishlist.external_id_numeric}")
    end
  end

  describe "#followed_by?" do
    let(:wishlist) { create(:wishlist) }
    let(:user) { create(:user) }

    context "when the user is following the wishlist" do
      before do
        create(:wishlist_follower, wishlist: wishlist, follower_user: user)
      end

      it "returns true" do
        expect(wishlist.followed_by?(user)).to eq(true)
      end
    end

    context "when the user has unfollowed the wishlist" do
      before do
        create(:wishlist_follower, wishlist: wishlist, follower_user: user, deleted_at: Time.current)
      end

      it "returns false" do
        expect(wishlist.followed_by?(user)).to eq(false)
      end
    end

    context "when the user is not following the wishlist" do
      it "returns false" do
        expect(wishlist.followed_by?(user)).to eq(false)
      end
    end
  end

  describe "#wishlist_products_for_email" do
    let(:wishlist) { create(:wishlist) }
    let(:old_product) { create(:wishlist_product, wishlist: wishlist, created_at: 1.day.ago) }
    let(:new_product) { create(:wishlist_product, wishlist: wishlist, created_at: 1.hour.ago) }
    let(:deleted_product) { create(:wishlist_product, wishlist: wishlist, deleted_at: Time.current) }

    context "when no email has been sent yet" do
      it "returns alive products" do
        expect(wishlist.wishlist_products_for_email).to match_array([old_product, new_product])
      end
    end

    context "when an email has been sent" do
      before { wishlist.update!(followers_last_contacted_at: 12.hours.ago) }

      it "returns alive products added after the last email" do
        expect(wishlist.wishlist_products_for_email).to eq([new_product])
      end
    end
  end

  describe "#update_recommendable" do
    let(:wishlist) { create(:wishlist, name: "My Wishlist") }

    before do
      create(:wishlist_product, wishlist:)
    end

    context "when there are alive wishlist products" do
      it "sets recommendable to true" do
        wishlist.update_recommendable
        expect(wishlist.recommendable).to be true
      end
    end

    context "when there are no alive wishlist products" do
      before { wishlist.wishlist_products.each(&:mark_deleted!) }

      it "sets recommendable to false" do
        wishlist.update_recommendable
        expect(wishlist.recommendable).to be false
      end
    end

    context "when name is adult" do
      before do
        allow(AdultKeywordDetector).to receive(:adult?).with(wishlist.name).and_return(true)
        allow(AdultKeywordDetector).to receive(:adult?).with(wishlist.description).and_return(false)
      end

      it "sets recommendable to false" do
        wishlist.update_recommendable
        expect(wishlist.recommendable).to be false
      end
    end

    context "when description is adult" do
      before do
        allow(AdultKeywordDetector).to receive(:adult?).with(wishlist.name).and_return(false)
        allow(AdultKeywordDetector).to receive(:adult?).with(wishlist.description).and_return(true)
      end

      it "sets recommendable to false" do
        wishlist.update_recommendable
        expect(wishlist.recommendable).to be false
      end
    end

    context "when discover is opted out" do
      before { wishlist.discover_opted_out = true }

      it "sets recommendable to false" do
        wishlist.update_recommendable
        expect(wishlist.recommendable).to be false
      end
    end

    context "when name is a default auto-generated one" do
      before { wishlist.name = "Wishlist 1" }

      it "sets recommendable to false" do
        wishlist.update_recommendable
        expect(wishlist.recommendable).to be false
      end
    end

    context "when save is true" do
      before { wishlist.discover_opted_out = true }

      it "saves the record" do
        wishlist.update_recommendable(save: true)
        expect(wishlist.reload.recommendable).to be false
      end
    end

    context "when save is false" do
      before { wishlist.discover_opted_out = true }

      it "does not save the record" do
        wishlist.update_recommendable(save: false)
        expect(wishlist.recommendable).to be false
        expect(wishlist.reload.recommendable).to be true
      end
    end
  end
end
