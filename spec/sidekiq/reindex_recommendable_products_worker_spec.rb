# frozen_string_literal: true

require "spec_helper"

describe ReindexRecommendableProductsWorker do
  it "updates time-dependent fields" do
    freeze_time

    products = create_list(:product, 5)
    allow(products[0]).to receive(:recommendable?).and_return(true)
    create(:purchase, link: products[0])

    allow(products[1]).to receive(:recommendable?).and_return(false)
    allow(products[1]).to receive(:created_at).and_return(1.second.from_now)
    create(:purchase, link: products[1])

    allow(products[2]).to receive(:recommendable?).and_return(true)
    allow(products[2]).to receive(:created_at).and_return(2.seconds.from_now)
    create(:purchase, link: products[2])

    allow(products[3]).to receive(:recommendable?).and_return(true)
    allow(products[3]).to receive(:created_at).and_return(3.seconds.from_now)
    create(:purchase, link: products[3])

    allow(products[4]).to receive(:recommendable?).and_return(true)
    allow(products[4]).to receive(:created_at).and_return(4.seconds.from_now)
    create(:purchase, link: products[4], created_at: Product::Searchable::DEFAULT_SALES_VOLUME_RECENTNESS.ago - 1.day)

    Link.__elasticsearch__.create_index!(force: true)
    products.each { |product| product.__elasticsearch__.index_document }
    Link.__elasticsearch__.refresh_index!

    stub_const("#{described_class}::SCROLL_SIZE", 2)
    stub_const("#{described_class}::SCROLL_SORT", ["created_at"])

    expect(Sidekiq::Client).to receive(:push_bulk).with(
      "class" => SendToElasticsearchWorker,
      "args" => [
        [products[0].id, "update", ["sales_volume", "total_fee_cents", "past_year_fee_cents"]],
        [products[2].id, "update", ["sales_volume", "total_fee_cents", "past_year_fee_cents"]]
      ],
      "queue" => "low",
      "at" => Time.current.to_i
    )
    expect(Sidekiq::Client).to receive(:push_bulk).with(
      "class" => SendToElasticsearchWorker,
      "args" => [
        [products[3].id, "update", ["sales_volume", "total_fee_cents", "past_year_fee_cents"]]
      ],
      "queue" => "low",
      "at" => 1.minute.from_now.to_i
    )

    described_class.new.perform
  end
end
