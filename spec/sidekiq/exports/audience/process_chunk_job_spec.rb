# frozen_string_literal: true

require "spec_helper"

describe Exports::Audience::ProcessChunkJob do
  let(:seller) { create(:user) }
  let(:export) { create(:audience_export, seller: seller) }

  describe "#perform" do
    context "when there are still chunks to process" do
      let!(:chunk_1) { create(:audience_export_chunk, export: export, processed: false) }
      let!(:chunk_2) { create(:audience_export_chunk, export: export, processed: false) }

      before do
        member1 = create(:audience_member, seller: seller, email: "user1@example.com",
          details: { "follower" => { "id" => 1, "created_at" => "2024-01-01 00:00:00" } })
        member2 = create(:audience_member, seller: seller, email: "user2@example.com",
          details: { "follower" => { "id" => 2, "created_at" => "2024-01-02 00:00:00" } })
        chunk_1.update!(member_ids: [member1.id])
        chunk_2.update!(member_ids: [member2.id])
      end

      it "processes the chunk and marks it as processed" do
        described_class.new.perform(chunk_1.id)
        chunk_1.reload

        expect(chunk_1.processed).to be(true)
        expect(chunk_1.members_data.size).to eq(1)
        expect(chunk_1.members_data.first.first).to eq("user1@example.com")
      end

      it "does not trigger CompileChunksJob when other chunks are pending" do
        described_class.new.perform(chunk_1.id)

        expect(Exports::Audience::CompileChunksJob).not_to have_enqueued_sidekiq_job(export.id)
      end
    end

    context "when this is the last chunk" do
      let!(:chunk_1) { create(:audience_export_chunk, export: export, processed: true, members_data: [["done@example.com", "2024-01-01"]]) }
      let!(:chunk_2) { create(:audience_export_chunk, export: export, processed: false) }

      before do
        member = create(:audience_member, seller: seller, email: "last@example.com",
          details: { "follower" => { "id" => 1, "created_at" => "2024-01-03 00:00:00" } })
        chunk_2.update!(member_ids: [member.id])
      end

      it "triggers CompileChunksJob" do
        described_class.new.perform(chunk_2.id)

        expect(Exports::Audience::CompileChunksJob).to have_enqueued_sidekiq_job(export.id)
      end
    end

    context "with multiple members in a chunk" do
      let!(:chunk) { create(:audience_export_chunk, export: export) }

      before do
        members = 3.times.map do |i|
          create(:audience_member, seller: seller, email: "user#{i}@example.com",
            details: { "follower" => { "id" => i, "created_at" => (3 - i).days.ago.iso8601 } })
        end
        chunk.update!(member_ids: members.map(&:id))
      end

      it "processes all members and orders by min_created_at" do
        described_class.new.perform(chunk.id)
        chunk.reload

        expect(chunk.members_data.size).to eq(3)
        emails = chunk.members_data.map(&:first)
        expect(emails).to eq(["user2@example.com", "user1@example.com", "user0@example.com"])
      end
    end
  end
end
