# frozen_string_literal: true

require "spec_helper"

describe ProductPageView do
  it "can have documents added to its index" do
    document_id = SecureRandom.uuid
    EsClient.index(
      index: described_class.index_name,
      id: document_id,
      body: {
        "product_id" => 123,
        "seller_id" => 456,
        "timestamp" => Time.utc(2021, 10, 20, 1, 2, 3)
      }.to_json
    )

    document = EsClient.get(index: described_class.index_name, id: document_id).fetch("_source")
    expect(document).to eq(
      "product_id" => 123,
      "seller_id" => 456,
      "timestamp" => "2021-10-20T01:02:03Z"
    )
  end
end
