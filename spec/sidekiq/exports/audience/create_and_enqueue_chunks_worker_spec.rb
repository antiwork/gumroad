# frozen_string_literal: true

require "spec_helper"

describe Exports::Audience::CreateAndEnqueueChunksWorker do
  let(:seller) { create(:user) }
  let!(:follower_1) { create(:active_follower, user: seller, created_at: 1.day.ago) }
  let!(:follower_2) { create(:active_follower, user: seller, created_at: 2.days.ago) }
  let!(:follower_3) { create(:active_follower, user: seller, created_at: 3.days.ago) }

  before do
    stub_const("#{described_class}::MAX_MEMBERS_PER_CHUNK", 2)
  end

  describe "#perform" do
    let!(:export) { create(:audience_export, seller:, audience_options: { followers: true }) }

    it "creates and enqueues a job for each generated chunk" do
      described_class.new.perform(export.id)
      export.reload

      expect(export.chunks.count).to eq(2)
      # Ordered by min_created_at (oldest first), batched by 2
      expect(export.chunks.first.audience_member_ids.size).to eq(2)
      expect(export.chunks.second.audience_member_ids.size).to eq(1)

      expect(Exports::Audience::ProcessChunkWorker).to have_enqueued_sidekiq_job(export.chunks.first.id)
      expect(Exports::Audience::ProcessChunkWorker).to have_enqueued_sidekiq_job(export.chunks.second.id)
    end

    it "deletes stale chunks on retry" do
      create(:audience_export_chunk, export:, audience_member_ids: [999])
      expect(export.chunks.count).to eq(1)

      described_class.new.perform(export.id)
      export.reload

      expect(export.chunks.count).to eq(2)
      expect(export.chunks.pluck(:audience_member_ids).flatten).not_to include(999)
    end

    context "with multiple audience types" do
      let(:product) { create(:product, user: seller, name: "Product 1") }
      let!(:customer) { create(:free_purchase, seller:, link: product, created_at: 5.days.ago) }
      let!(:export) { create(:audience_export, seller:, audience_options: { followers: true, customers: true }) }

      it "includes all selected audience types" do
        described_class.new.perform(export.id)
        export.reload

        all_ids = export.chunks.pluck(:audience_member_ids).flatten
        expect(all_ids.size).to eq(4) # 3 followers + 1 customer
      end
    end
  end
end
