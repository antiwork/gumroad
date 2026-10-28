# frozen_string_literal: true

require "spec_helper"

describe SendToElasticsearchWorker do
  before do
    @product = create(:product)
    @product_double = double("product")
  end

  it "is unique while it waits to run, so a burst of changes to one product collapses into one job" do
    expect(described_class.get_sidekiq_options["lock"]).to eq(:until_executing)
  end

  it "bounds a stranded lock with a TTL" do
    expect(described_class.get_sidekiq_options["lock_ttl"]).to eq(10.minutes.to_i)
  end

  it "marks a duplicate instead of replacing the waiting job, because :replace scans the whole schedule set in Lua" do
    expect(described_class.get_sidekiq_options["on_conflict"]).to eq(:mark_for_trailing_run)

    args = [@product.id, "update", %w[sales_volume]]
    described_class::MarkForTrailingRun.new("args" => args).call

    expect(Sidekiq.redis { _1.call("EXISTS", described_class.trailing_key(args)) }).to eq(1)
    expect(Sidekiq.redis { _1.call("TTL", described_class.trailing_key(args)) }).to be_between(1, 10.minutes.to_i)
  end

  context "when a duplicate was dropped while the job waited" do
    let(:args) { [@product.id, "update", %w[sales_volume]] }

    before { described_class::MarkForTrailingRun.new("args" => args).call }

    it "queues one trailing run so a later sale still reaches the totals" do
      allow(ProductIndexingService).to receive(:perform)

      expect(described_class).to receive(:perform_in).with(5.seconds, *args).once

      described_class.new.perform(*args)
      described_class.new.perform(*args)
    end

    it "does not queue a trailing run when indexing raises" do
      allow(ProductIndexingService).to receive(:perform).and_raise("boom")

      expect(described_class).not_to receive(:perform_in)

      expect { described_class.new.perform(*args) }.to raise_error("boom")
    end
  end

  it "does not queue a trailing run when no duplicate was dropped" do
    allow(ProductIndexingService).to receive(:perform)

    expect(described_class).not_to receive(:perform_in)

    described_class.new.perform(@product.id, "update", %w[sales_volume])
  end

  it "reads the product from the primary" do
    expect(ApplicationRecord).to receive(:connected_to).with(role: :writing).and_call_original
    expect(ProductIndexingService).to receive(:perform).with(product: @product, action: "update", attributes_to_update: %w[is_recommendable])

    SendToElasticsearchWorker.new.perform(@product.id, "update", %w[is_recommendable])
  end

  it "attempts to index the product in Elasticsearch when instructed" do
    expect(Link).to receive(:find_by).with(id: @product.id)
    allow(Link).to receive(:find_by).with(id: @product.id).and_return(@product_double)

    expect(@product_double).to receive_message_chain(:__elasticsearch__, :index_document)

    SendToElasticsearchWorker.new.perform(@product.id, "index")
  end

  it "attempts to update the search index for the product in Elasticsearch when instructed" do
    @product.update!(name: "Searching for Robby Fischer")
    @product.tag!("tag")
    search_update = @product.build_search_update(%w[name tags])

    expect(Link).to receive(:find_by).with(id: @product.id)
    allow(Link).to receive(:find_by).with(id: @product.id).and_return(@product_double)

    allow(@product_double).to receive(:build_search_update).with(%w[name tags]).and_return(search_update)
    expect(@product_double).to(
      receive_message_chain(:__elasticsearch__, :update_document_attributes).with(
        search_update.as_json
      )
    )

    SendToElasticsearchWorker.new.perform(@product.id, "update", %w[name tags])
  end

  it "does not attempt to update the search index for the product in Elasticsearch " \
     "when instructed with no attributes_to_update" do
    expect(Link).to receive(:find_by).with(id: @product.id)
    allow(Link).to receive(:find_by).with(id: @product.id).and_return(@product_double)

    expect(@product_double).to_not receive(:build_search_update)

    SendToElasticsearchWorker.new.perform(@product.id, "update", [])
  end
end
