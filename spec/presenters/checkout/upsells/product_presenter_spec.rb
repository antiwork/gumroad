# frozen_string_literal: true

require "spec_helper"

describe Checkout::Upsells::ProductPresenter do
  let!(:product) do
    create(
      :product,
      name: "Test Product",
      price_cents: 1000,
      native_type: "ebook"
    )
  end
  let(:presenter) { described_class.new(product) }

  before do
    create(:free_purchase, :with_review, link: product)
  end

  describe "#product_props" do
    it "returns product properties hash" do
      expect(presenter.product_props).to eq(
        id: product.external_id,
        permalink: product.unique_permalink,
        name: "Test Product",
        price_cents: 1000,
        currency_code: "usd",
        review_count: 1,
        average_rating: 5.0,
        native_type: "ebook",
        thumbnail_url: nil,
        options: []
      )
    end

    it "includes thumbnail_url when product has a thumbnail" do
      thumbnail = create(:thumbnail, product:)

      expect(presenter.product_props[:thumbnail_url]).to eq(thumbnail.url)
    end
  end
end
