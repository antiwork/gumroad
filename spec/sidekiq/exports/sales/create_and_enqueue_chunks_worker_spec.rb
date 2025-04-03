# frozen_string_literal: true

require "spec_helper"

describe Exports::Sales::CreateAndEnqueueChunksWorker do
  before do
    seller = create(:user)
    product = create(:product, user: seller)
    @purchases = create_list(:purchase, 3, link: product)
    @export = create(:sales_export, query: PurchaseSearchService.new(seller:).query.deep_stringify_keys)
    index_model_records(Purchase)
    stub_const("#{described_class}::MAX_PURCHASES_PER_CHUNK", 2)
  end

  it "creates and enqueues a job for each generated chunk" do
    described_class.new.perform(@export.id)
    @export.reload

    expect(@export.chunks.count).to eq(2)
    expect(@export.chunks.first.purchase_ids).to eq([@purchases[0].id, @purchases[1].id])
    expect(@export.chunks.second.purchase_ids).to eq([@purchases[2].id])

    expect(Exports::Sales::ProcessChunkWorker).to have_enqueued_sidekiq_job(@export.chunks.first.id)
    expect(Exports::Sales::ProcessChunkWorker).to have_enqueued_sidekiq_job(@export.chunks.second.id)
  end
end
