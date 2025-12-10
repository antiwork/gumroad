# frozen_string_literal: true

require "spec_helper"

describe Exports::Audience::CreateAndEnqueueChunksWorker do
  let(:seller) { create(:user) }
  let(:recipient) { create(:user) }

  let!(:follower1) do
    create(:audience_member, seller:, email: "follower1@example.com",
      follower: { id: 1, created_at: 1.day.ago.iso8601 })
  end
  let!(:follower2) do
    create(:audience_member, seller:, email: "follower2@example.com",
      follower: { id: 2, created_at: 2.days.ago.iso8601 })
  end
  let!(:follower3) do
    create(:audience_member, seller:, email: "follower3@example.com",
      follower: { id: 3, created_at: 3.days.ago.iso8601 })
  end

  let(:export) { create(:audience_export, seller:, recipient:, options: { followers: true }) }

  before do
    stub_const("#{described_class}::MAX_MEMBERS_PER_CHUNK", 2)
  end

  it "creates and enqueues a job for each generated chunk" do
    described_class.new.perform(export.id)
    export.reload

    expect(export.chunks.count).to eq(2)
    expect(export.chunks.map(&:member_ids).flatten).to contain_exactly(follower1.id, follower2.id, follower3.id)

    expect(Exports::Audience::ProcessChunkWorker).to have_enqueued_sidekiq_job(export.chunks.first.id)
    expect(Exports::Audience::ProcessChunkWorker).to have_enqueued_sidekiq_job(export.chunks.second.id)
  end

  it "filters by audience type" do
    customer = create(:audience_member, seller:, email: "customer@example.com",
      purchases: [{ id: 1, product_id: 1, price_cents: 100, created_at: 1.day.ago.iso8601, country: "US" }])

    export_customers = create(:audience_export, seller:, recipient:, options: { customers: true })

    described_class.new.perform(export_customers.id)
    export_customers.reload

    expect(export_customers.chunks.count).to eq(1)
    expect(export_customers.chunks.first.member_ids).to eq([customer.id])
  end

  it "deletes stale chunks when retrying" do
    stale_chunk = create(:audience_export_chunk, export:, member_ids: [999])

    described_class.new.perform(export.id)
    export.reload

    expect(export.chunks.pluck(:id)).not_to include(stale_chunk.id)
    expect(export.chunks.count).to eq(2)
  end
end
