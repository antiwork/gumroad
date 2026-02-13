# frozen_string_literal: true

require "spec_helper"

describe CheckMissedPostsCompletionJob do
  describe "#perform" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product, seller:) }

    before do
      $redis.set(RedisKey.send_missed_posts(purchase.id, "all"), "1", ex: 3.days.to_i)
    end

    it "clears the Redis lock when no missed posts remain" do
      described_class.new.perform(purchase.id)

      expect($redis.get(RedisKey.send_missed_posts(purchase.id, "all"))).to be_nil
    end

    it "re-enqueues itself when missed posts still remain" do
      create(:installment, link: product, seller:, published_at: 1.day.ago)

      described_class.new.perform(purchase.id, nil, 1)

      expect(CheckMissedPostsCompletionJob).to have_enqueued_sidekiq_job(purchase.id, nil, 2)
    end

    it "clears the Redis lock and stops retrying at MAX_ATTEMPTS" do
      create(:installment, link: product, seller:, published_at: 1.day.ago)

      described_class.new.perform(purchase.id, nil, 4)

      expect($redis.get(RedisKey.send_missed_posts(purchase.id, "all"))).to be_nil
      expect(CheckMissedPostsCompletionJob.jobs.size).to eq(0)
    end

    it "increments the attempt count on each retry" do
      create(:installment, link: product, seller:, published_at: 1.day.ago)

      described_class.new.perform(purchase.id, nil, 3)

      expect(CheckMissedPostsCompletionJob).to have_enqueued_sidekiq_job(purchase.id, nil, 4)
    end

    context "with workflow_id filtering" do
      let(:workflow) { create(:workflow, seller:, link: product) }

      before do
        $redis.set(RedisKey.send_missed_posts(purchase.id, workflow.id), "1", ex: 3.days.to_i)
      end

      it "only checks posts for the specified workflow" do
        create(:installment, link: product, seller:, published_at: 1.day.ago)
        create(:installment, link: product, seller:, published_at: 1.day.ago, workflow:)

        described_class.new.perform(purchase.id, workflow.id)

        expect(CheckMissedPostsCompletionJob).to have_enqueued_sidekiq_job(purchase.id, workflow.id, 2)
      end

      it "clears the workflow-specific lock when those posts are all sent" do
        create(:installment, link: product, seller:, published_at: 1.day.ago)

        described_class.new.perform(purchase.id, workflow.id)

        expect($redis.get(RedisKey.send_missed_posts(purchase.id, workflow.id))).to be_nil
      end
    end
  end
end
