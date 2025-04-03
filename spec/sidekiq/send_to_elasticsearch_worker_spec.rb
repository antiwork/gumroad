# frozen_string_literal: true

require "spec_helper"

describe SendToElasticsearchWorker do
  before do
    @product = create(:product)
    @product_double = double("product")
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
