# frozen_string_literal: true

require "spec_helper"

describe SendWishlistUpdatedEmailsJob do
  let(:wishlist) { create(:wishlist) }
  let(:wishlist_follower) { create(:wishlist_follower, wishlist: wishlist, created_at: 10.minutes.ago) }
  let(:wishlist_product) { create(:wishlist_product, wishlist: wishlist, created_at: 5.minutes.ago) }
  let(:wishlist_product_ids) { [wishlist_product.id] }

  describe "#perform" do
    it "sends an email to the wishlist follower" do
      expect(CustomerLowPriorityMailer).to receive(:wishlist_updated).with(wishlist_follower.id, 1).and_call_original
      described_class.new.perform(wishlist.id, wishlist_product_ids)
    end

    it "updates the last contacted at timestamp" do
      described_class.new.perform(wishlist.id, wishlist_product_ids)
      expect(wishlist.reload.followers_last_contacted_at).to eq(wishlist_product.created_at)
    end

    context "when the wishlist has no new products" do
      let(:wishlist_product_ids) { [] }

      it "does not send an email" do
        expect(CustomerLowPriorityMailer).not_to receive(:wishlist_updated)
        described_class.new.perform(wishlist.id, wishlist_product_ids)
      end

      it "does not update the last contacted at timestamp" do
        described_class.new.perform(wishlist.id, wishlist_product_ids)
        expect(wishlist.reload.followers_last_contacted_at).to be_nil
      end
    end

    context "when a product was added before a user followed" do
      let(:wishlist_product_2) { create(:wishlist_product, wishlist: wishlist, created_at: 1.hour.ago) }
      let(:wishlist_product_ids) { [wishlist_product.id, wishlist_product_2.id] }
      let(:old_follower) { create(:wishlist_follower, wishlist: wishlist, created_at: 2.hours.ago) }

      it "excludes the product from emails to new followers" do
        expect(CustomerLowPriorityMailer).to receive(:wishlist_updated).with(old_follower.id, 2).and_call_original
        expect(CustomerLowPriorityMailer).to receive(:wishlist_updated).with(wishlist_follower.id, 1).and_call_original
        described_class.new.perform(wishlist.id, wishlist_product_ids)
      end
    end

    context "when another product was added after the job was scheduled" do
      let!(:newer_product) { create(:wishlist_product, wishlist: wishlist, created_at: 1.minute.ago) }

      it "does nothing since the job for the newer product is expected to send the email" do
        expect(CustomerLowPriorityMailer).not_to receive(:wishlist_updated)
        described_class.new.perform(wishlist.id, wishlist_product_ids)
      end
    end
  end
end
