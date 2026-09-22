# frozen_string_literal: true

require "spec_helper"

describe Onetime::ReindexStalePurchaseStates, :elasticsearch_wait_for_refresh do
  let(:created_after) { 2.days.ago }
  let(:created_before) { 1.day.ago }

  it "repairs successful and failed states through the indexer and is repeatable" do
    purchases = %w[successful failed].map do |state|
      create(:purchase, purchase_state: state, created_at: 36.hours.ago)
    end
    purchases.each do |purchase|
      EsClient.index(index: Purchase.index_name, id: purchase.id, body: purchase.as_indexed_json.merge("purchase_state" => "in_progress"))
    end
    EsClient.indices.refresh(index: Purchase.index_name)
    ids = purchases.map(&:id)
    expect(described_class.candidate_ids(created_after:, created_before:)).to eq(ids)

    2.times do
      expect(described_class.perform(ids:, created_after:, created_before:)).to eq(ids)
      purchases.each do |purchase|
        expect(EsClient.get(index: Purchase.index_name, id: purchase.id).dig("_source", "purchase_state")).to eq(purchase.purchase_state)
      end
    end
    EsClient.indices.refresh(index: Purchase.index_name)
    expect(described_class.candidate_ids(created_after:, created_before:)).to eq([])
  end

  it "rejects missing and out-of-window records before writing any document" do
    purchase = create(:purchase, created_at: created_after - 1.second)
    expect(EsClient).not_to receive(:index)
    expect { described_class.perform(ids: [purchase.id], created_after:, created_before:) }.to raise_error(/out-of-window/)
    expect { described_class.perform(ids: [0], created_after:, created_before:) }.to raise_error(/missing/)
  end

  it "rejects unbounded or duplicate batches" do
    [[], [1, 1], (1..101).to_a].each do |ids|
      expect { described_class.perform(ids:, created_after:, created_before:) }.to raise_error(ArgumentError)
    end
  end

  it "refuses a truncated candidate set" do
    allow(EsClient).to receive(:search).and_return("hits" => { "total" => { "value" => 5_001 } })
    expect { described_class.candidate_ids(created_after:, created_before:) }.to raise_error(/limit exceeded/)
  end
end
