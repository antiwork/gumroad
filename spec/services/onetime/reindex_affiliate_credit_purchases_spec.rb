# frozen_string_literal: true

require "spec_helper"

describe Onetime::ReindexAffiliateCreditPurchases, :elasticsearch_wait_for_refresh do
  it "restores blank affiliate credit fields on the purchase doc, in resumable batches" do
    credits = create_list(:affiliate_credit, 2)
    credits.each do |credit|
      EsClient.index(index: Purchase.index_name, id: credit.purchase_id, body: credit.purchase.as_indexed_json.merge("affiliate_credit_amount_cents" => nil), refresh: true)
    end

    first = described_class.perform(limit: 1)
    expect(first).to eq(enqueued: 1, last_credit_id: credits.first.id)
    second = described_class.perform(after_id: first[:last_credit_id], limit: 1)
    expect(second).to eq(enqueued: 1, last_credit_id: credits.last.id)
    expect(described_class.perform(after_id: second[:last_credit_id])).to eq(enqueued: 0, last_credit_id: nil)

    ElasticsearchIndexerWorker.drain
    credits.each do |credit|
      source = EsClient.get(index: Purchase.index_name, id: credit.purchase_id).fetch("_source")
      expect(source["affiliate_credit_amount_cents"]).to eq(credit.amount_cents)
    end
  end
end
