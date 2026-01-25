# frozen_string_literal: true

require "spec_helper"

describe Exports::Audience::ProcessChunkWorker do
  let(:seller) { create(:user) }
  let!(:export) { create(:audience_export, seller:, options: { followers: true }) }

  before do
    @worker = described_class.new
  end

  context "when there are still chunks to process" do
    let!(:follower_1) { create(:active_follower, user: seller, created_at: 1.day.ago) }
    let!(:follower_2) { create(:active_follower, user: seller, created_at: 2.days.ago) }
    let!(:chunk_1) { create(:audience_export_chunk, export:, audience_member_ids: [seller.audience_members.first.id]) }
    let!(:chunk_2) { create(:audience_export_chunk, export:, audience_member_ids: [seller.audience_members.second.id]) }

    it "does not trigger compile worker" do
      expect(Exports::Audience::CompileChunksWorker).not_to receive(:perform_async)
      @worker.perform(chunk_2.id)
    end

    it "updates chunk with processed data" do
      @worker.perform(chunk_2.id)
      chunk_2.reload

      expect(chunk_2.processed).to eq(true)
      expect(chunk_2.revision).to eq(REVISION)
      expect(chunk_2.audience_data.size).to eq(1)
      expect(chunk_2.audience_data.first.first).to eq(follower_2.email)
    end
  end

  context "when all chunks are processed" do
    let!(:follower) { create(:active_follower, user: seller, created_at: 1.day.ago) }
    let!(:chunk) { create(:audience_export_chunk, export:, audience_member_ids: [seller.audience_members.first.id]) }

    it "triggers compile worker" do
      expect(Exports::Audience::CompileChunksWorker).to receive(:perform_async).with(export.id)
      @worker.perform(chunk.id)
    end
  end

  context "when chunks were processed with another revision" do
    let!(:follower_1) { create(:active_follower, user: seller, created_at: 1.day.ago) }
    let!(:follower_2) { create(:active_follower, user: seller, created_at: 2.days.ago) }
    let!(:chunk_1) { create(:audience_export_chunk, export:, audience_member_ids: [seller.audience_members.first.id], processed: true, revision: "old-revision") }
    let!(:chunk_2) { create(:audience_export_chunk, export:, audience_member_ids: [seller.audience_members.second.id]) }

    it "does not trigger compile worker" do
      expect(Exports::Audience::CompileChunksWorker).not_to receive(:perform_async)
      @worker.perform(chunk_2.id)
    end

    it "requeues chunks that were processed with another revision" do
      @worker.perform(chunk_2.id)
      expect(described_class).to have_enqueued_sidekiq_job(chunk_1.id)
    end
  end
end
