# frozen_string_literal: true

require "spec_helper"

describe MissedPostsDeliveryService do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, link: product, seller:) }

  let!(:post1) { create(:installment, link: product, seller:, published_at: 2.days.ago) }
  let!(:post2) { create(:installment, link: product, seller:, published_at: 1.day.ago) }

  let(:service) { described_class.new(purchase:) }

  before do
    allow(PostEmailApi).to receive(:process)
  end

  describe "#missed_posts" do
    it "returns missed posts for the purchase" do
      expect(service.missed_posts.to_a).to match_array([post1, post2])
    end

    it "filters by workflow_id when provided" do
      workflow = create(:workflow, seller:, link: product)
      post1.update_column(:workflow_id, workflow.id)

      result = service.missed_posts(workflow_id: workflow.id)

      expect(result.to_a).to eq([post1])
    end

    it "excludes posts already delivered to the purchase" do
      create(:creator_contacting_customers_email_info_delivered, installment: post1, purchase:)

      expect(service.missed_posts.to_a).to eq([post2])
    end
  end

  describe "#deliver_all" do
    it "sends each missed post via PostEmailApi" do
      service.deliver_all

      expect(PostEmailApi).to have_received(:process).twice
    end

    it "cleans up old email info before resending" do
      old_info = create(:creator_contacting_customers_email_info, installment: post1, purchase:)
      allow(Installment).to receive(:missed_for_purchase).with(purchase).and_return(Installment.where(id: [post1.id, post2.id]))

      service.deliver_all

      expect(CreatorContactingCustomersEmailInfo.where(id: old_info.id)).not_to exist
    end

    it "sets a cache key for each sent post" do
      service.deliver_all

      expect(Rails.cache.exist?("post_email:#{post1.id}:#{purchase.id}")).to be(true)
      expect(Rails.cache.exist?("post_email:#{post2.id}:#{purchase.id}")).to be(true)
    end

    it "skips posts with an active cache entry" do
      Rails.cache.write("post_email:#{post1.id}:#{purchase.id}", true, expires_in: described_class::THROTTLE_PERIOD)

      service.deliver_all

      expect(PostEmailApi).to have_received(:process).once
    end

    it "continues delivering when one post fails" do
      call_count = 0
      allow(PostEmailApi).to receive(:process) do
        call_count += 1
        raise StandardError, "send failure" if call_count == 1
      end

      service.deliver_all

      expect(PostEmailApi).to have_received(:process).twice
    end

    it "does nothing when there are no missed posts" do
      create(:creator_contacting_customers_email_info_delivered, installment: post1, purchase:)
      create(:creator_contacting_customers_email_info_delivered, installment: post2, purchase:)

      service.deliver_all

      expect(PostEmailApi).not_to have_received(:process)
    end

    it "filters by workflow_id when provided" do
      workflow = create(:workflow, seller:, link: product)
      post1.update_column(:workflow_id, workflow.id)

      service.deliver_all(workflow_id: workflow.id)

      expect(PostEmailApi).to have_received(:process).once
    end

    it "passes correct recipient data to PostEmailApi" do
      post2.destroy!

      service.deliver_all

      expect(PostEmailApi).to have_received(:process).with(
        post: post1,
        recipients: [hash_including(email: purchase.email, purchase:)]
      )
    end
  end
end
