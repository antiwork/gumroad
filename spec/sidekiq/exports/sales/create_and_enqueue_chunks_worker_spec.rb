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

    expect(Exports::Sales::CompileChunksWorker).not_to have_enqueued_sidekiq_job(@export.id)
  end

  context "when the query matches no purchases" do
    before do
      other_seller = create(:user)
      @export.update!(query: PurchaseSearchService.new(seller: other_seller).query.deep_stringify_keys)
    end

    it "compiles directly so the empty CSV is still emailed and the export row is not orphaned" do
      described_class.new.perform(@export.id)
      @export.reload

      expect(@export.chunks.count).to eq(0)
      expect(Exports::Sales::ProcessChunkWorker.jobs).to be_empty
      expect(Exports::Sales::CompileChunksWorker).to have_enqueued_sidekiq_job(@export.id)
    end
  end
end
