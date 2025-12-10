# frozen_string_literal: true

require "spec_helper"

describe Exports::Audience::ProcessChunkWorker do
  let(:seller) { create(:user) }
  let(:recipient) { create(:user) }

  let!(:member1) do
    create(:audience_member, seller:, email: "member1@example.com",
      follower: { id: 1, created_at: 1.day.ago.iso8601 })
  end
  let!(:member2) do
    create(:audience_member, seller:, email: "member2@example.com",
      follower: { id: 2, created_at: 2.days.ago.iso8601 })
  end

  let(:export) { create(:audience_export, seller:, recipient:, options: { followers: true }) }
  let!(:chunk) { create(:audience_export_chunk, export:, member_ids: [member1.id, member2.id]) }

  describe "#perform" do
    context "when there are more chunks to process" do
      let!(:other_chunk) { create(:audience_export_chunk, export:, member_ids: [], processed: false) }

      it "processes the chunk and does not enqueue compile worker" do
        described_class.new.perform(chunk.id)
        chunk.reload

        expect(chunk.processed).to be(true)
        expect(chunk.csv_data.size).to eq(2)
        expect(chunk.csv_data.map(&:first)).to contain_exactly("member1@example.com", "member2@example.com")

        expect(Exports::Audience::CompileChunksWorker.jobs.size).to eq(0)
      end
    end

    context "when this is the last chunk to process" do
      it "processes the chunk and enqueues compile worker" do
        described_class.new.perform(chunk.id)
        chunk.reload

        expect(chunk.processed).to be(true)
        expect(Exports::Audience::CompileChunksWorker).to have_enqueued_sidekiq_job(export.id)
      end
    end
  end
end
