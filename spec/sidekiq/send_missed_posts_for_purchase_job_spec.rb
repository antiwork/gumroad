# frozen_string_literal: true

require "spec_helper"

describe SendMissedPostsForPurchaseJob do
  describe "#perform" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product, seller:) }

    let!(:post1) { create(:installment, link: product, seller:, published_at: 2.days.ago) }
    let!(:post2) { create(:installment, link: product, seller:, published_at: 1.day.ago) }
    let!(:post3) { create(:installment, link: product, seller:, published_at: 3.days.ago) }

    before do
      allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)
      allow(PostEmailApi).to receive(:process)
    end

    it "sends all missed posts for the purchase" do
      described_class.new.perform(purchase.id)

      expect(PostEmailApi).to have_received(:process).exactly(3).times
    end

    it "skips posts that were already sent" do
      create(:creator_contacting_customers_email_info_delivered, installment: post1, purchase:)

      described_class.new.perform(purchase.id)

      expect(PostEmailApi).to have_received(:process).exactly(2).times
    end

    it "respects the throttle period for recently sent posts" do
      Rails.cache.write("post_email:#{post1.id}:#{purchase.id}", true, expires_in: 8.hours)

      described_class.new.perform(purchase.id)

      expect(PostEmailApi).to have_received(:process).exactly(2).times
    end

    it "does not send if purchase cannot be contacted" do
      purchase.update!(can_contact: false)

      described_class.new.perform(purchase.id)

      expect(PostEmailApi).not_to have_received(:process)
    end

    it "does not send if seller is not eligible to send emails" do
      allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(false)

      described_class.new.perform(purchase.id)

      expect(PostEmailApi).not_to have_received(:process)
    end

    it "does not send unpublished posts" do
      create(:installment, link: product, seller:)

      described_class.new.perform(purchase.id)

      expect(PostEmailApi).to have_received(:process).exactly(3).times
    end

    it "includes workflow posts in the missed posts" do
      create(:installment, link: product, seller:, published_at: Time.current, workflow: create(:workflow))

      described_class.new.perform(purchase.id)

      expect(PostEmailApi).to have_received(:process).exactly(4).times
    end

    it "cleans up the old email info before resending" do
      old_email_info = create(:creator_contacting_customers_email_info, installment: post1, purchase:)
      allow(Installment).to receive(:missed_for_purchase).with(purchase).and_return(Installment.where(id: [post1.id, post2.id, post3.id]))

      described_class.new.perform(purchase.id)

      expect(CreatorContactingCustomersEmailInfo.where(id: old_email_info.id)).not_to exist
    end

    it "does not clear the Redis lock directly" do
      $redis.set(RedisKey.send_missed_posts(purchase.id), "1", ex: 3.days.to_i)

      described_class.new.perform(purchase.id)

      expect($redis.get(RedisKey.send_missed_posts(purchase.id))).to eq("1")
    end

    it "enqueues CheckMissedPostsCompletionJob after processing" do
      described_class.new.perform(purchase.id)

      expect(CheckMissedPostsCompletionJob).to have_enqueued_sidekiq_job(purchase.id, nil)
    end

    it "continues sending remaining posts when one fails" do
      call_count = 0
      allow(PostEmailApi).to receive(:process) do
        call_count += 1
        raise StandardError, "send failure" if call_count == 1
      end

      described_class.new.perform(purchase.id)

      expect(PostEmailApi).to have_received(:process).exactly(3).times
    end

    it "handles empty missed posts gracefully" do
      create(:creator_contacting_customers_email_info_delivered, installment: post1, purchase:)
      create(:creator_contacting_customers_email_info_delivered, installment: post2, purchase:)
      create(:creator_contacting_customers_email_info_delivered, installment: post3, purchase:)

      described_class.new.perform(purchase.id)

      expect(PostEmailApi).not_to have_received(:process)
    end

    it "passes the correct recipient data to PostEmailApi" do
      post2.destroy!
      post3.destroy!

      described_class.new.perform(purchase.id)

      expect(PostEmailApi).to have_received(:process).with(
        post: post1,
        recipients: [
          hash_including(
            email: purchase.email,
            purchase:,
          )
        ]
      )
    end

    it "sets the cache key for each sent post" do
      described_class.new.perform(purchase.id)

      expect(Rails.cache.exist?("post_email:#{post1.id}:#{purchase.id}")).to be(true)
      expect(Rails.cache.exist?("post_email:#{post2.id}:#{purchase.id}")).to be(true)
      expect(Rails.cache.exist?("post_email:#{post3.id}:#{purchase.id}")).to be(true)
    end

    context "with workflow_id filtering" do
      let(:workflow) { create(:workflow, seller:, link: product) }

      it "filters to only workflow posts when workflow_id is provided" do
        post1.update_column(:workflow_id, workflow.id)
        posts = Installment.where(id: [post1.id, post2.id, post3.id])
        allow(Installment).to receive(:missed_for_purchase).with(purchase).and_return(posts)

        described_class.new.perform(purchase.id, workflow.id)

        expect(PostEmailApi).to have_received(:process).once
      end

      it "sends all posts when workflow_id is nil" do
        described_class.new.perform(purchase.id, nil)

        expect(PostEmailApi).to have_received(:process).exactly(3).times
      end
    end
  end
end
