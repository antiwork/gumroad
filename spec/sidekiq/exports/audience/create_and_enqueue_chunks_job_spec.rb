# frozen_string_literal: true

require "spec_helper"

describe Exports::Audience::CreateAndEnqueueChunksJob do
  let(:seller) { create(:user) }
  let(:recipient) { create(:user) }
  let(:export) { create(:audience_export, seller: seller, recipient: recipient, followers: true) }

  before do
    stub_const("#{described_class}::CHUNK_SIZE", 2)
  end

  describe "#perform" do
    context "with audience members" do
      before do
        3.times do |i|
          create(:audience_member,
            seller: seller,
            email: "follower#{i}@example.com",
            details: { "follower" => { "id" => i, "created_at" => Time.current.iso8601 } }
          )
        end
      end

      it "creates chunks and enqueues ProcessChunkJob for each" do
        described_class.new.perform(export.id)
        export.reload

        expect(export.audience_export_chunks.count).to eq(2)
        expect(export.audience_export_chunks.first.member_ids.size).to eq(2)
        expect(export.audience_export_chunks.second.member_ids.size).to eq(1)

        expect(Exports::Audience::ProcessChunkJob).to have_enqueued_sidekiq_job(export.audience_export_chunks.first.id)
        expect(Exports::Audience::ProcessChunkJob).to have_enqueued_sidekiq_job(export.audience_export_chunks.second.id)
      end

      it "deletes stale chunks on retry" do
        create(:audience_export_chunk, audience_export: export, member_ids: [999])
        expect(export.audience_export_chunks.count).to eq(1)

        described_class.new.perform(export.id)
        export.reload

        expect(export.audience_export_chunks.count).to eq(2)
        expect(export.audience_export_chunks.pluck(:member_ids).flatten).not_to include(999)
      end
    end

    context "with empty audience" do
      it "triggers CompileChunksJob immediately" do
        described_class.new.perform(export.id)

        expect(export.audience_export_chunks.count).to eq(0)
        expect(Exports::Audience::CompileChunksJob).to have_enqueued_sidekiq_job(export.id)
      end
    end

    context "with different audience types" do
      before do
        create(:audience_member, seller: seller, email: "follower@example.com",
          details: { "follower" => { "id" => 1, "created_at" => Time.current.iso8601 } })
        create(:audience_member, seller: seller, email: "customer@example.com",
          details: { "purchases" => [{ "id" => 1, "product_id" => 1, "price_cents" => 1000, "created_at" => Time.current.iso8601 }] })
      end

      it "only includes followers when followers option is set" do
        described_class.new.perform(export.id)
        export.reload

        expect(export.audience_export_chunks.count).to eq(1)
        expect(export.audience_export_chunks.first.member_ids.size).to eq(1)
      end

      it "includes both when both options are set" do
        export.update!(followers: true, customers: true)
        described_class.new.perform(export.id)
        export.reload

        expect(export.audience_export_chunks.first.member_ids.size).to eq(2)
      end
    end
  end
end
