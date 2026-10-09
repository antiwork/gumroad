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

    it "does not enqueue duplicate emails when the job is replayed" do
      wishlist_follower

      expect do
        described_class.new.perform(wishlist.id, wishlist_product_ids)
        described_class.new.perform(wishlist.id, wishlist_product_ids)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :wishlist_updated)
        .with(wishlist_follower.id, 1).on_queue(:low).once
    end

    it "retries an email after its enqueue fails" do
      wishlist_follower
      adapter = MailDeliveryJob.queue_adapter
      allow(adapter).to receive(:enqueue).and_raise("queue unavailable")

      expect do
        described_class.new.perform(wishlist.id, wishlist_product_ids)
      end.to raise_error("queue unavailable")

      expect(wishlist.reload.followers_last_contacted_at).to be_nil
      expect(SentEmailInfo.mailer_exists?("CustomerLowPriorityMailer", "wishlist_updated", wishlist_follower.id, wishlist_product_ids)).to be(false)

      allow(adapter).to receive(:enqueue).and_call_original

      expect do
        described_class.new.perform(wishlist.id, wishlist_product_ids)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :wishlist_updated)
        .with(wishlist_follower.id, 1).on_queue(:low).once

      expect(wishlist.reload.followers_last_contacted_at).to eq(wishlist_product.created_at)
    end

    it "retries only remaining followers after a partial enqueue" do
      wishlist_follower
      another_buyer = create(:user, email: "another-follower@example.com")
      another_follower = create(:wishlist_follower, wishlist:, follower_user: another_buyer, created_at: 10.minutes.ago)
      adapter = MailDeliveryJob.queue_adapter
      previously_enqueued_emails = adapter.enqueued_jobs.count { _1[:args][1] == "wishlist_updated" }
      enqueue_count = 0
      allow(adapter).to receive(:enqueue).and_wrap_original do |original, job|
        enqueue_count += 1
        raise "queue unavailable" if enqueue_count == 2

        original.call(job)
      end

      expect do
        described_class.new.perform(wishlist.id, wishlist_product_ids)
      end.to raise_error("queue unavailable")

      expect(wishlist.reload.followers_last_contacted_at).to be_nil
      expect(SentEmailInfo.mailer_exists?("CustomerLowPriorityMailer", "wishlist_updated", wishlist_follower.id, wishlist_product_ids)).to be(true)
      expect(SentEmailInfo.mailer_exists?("CustomerLowPriorityMailer", "wishlist_updated", another_follower.id, wishlist_product_ids)).to be(false)

      allow(adapter).to receive(:enqueue).and_call_original

      expect do
        described_class.new.perform(wishlist.id, wishlist_product_ids)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :wishlist_updated)
        .with(another_follower.id, 1).on_queue(:low).once

      expect(adapter.enqueued_jobs.count { _1[:args][1] == "wishlist_updated" }).to eq(previously_enqueued_emails + 2)
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
