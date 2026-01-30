# frozen_string_literal: true

require "spec_helper"

describe BundleSearchProductsService do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:bundle) { create(:product, :bundle, user: seller) }
  let(:other_seller) { create(:user) }

  before do
    index_model_records(Link)
  end

  describe "#call" do
    it "excludes the bundle itself from results" do
      product1 = create(:product, user: seller)
      product2 = create(:product, user: seller)
      index_model_records(Link)

      result = described_class.new(bundle:, seller:).call

      product_ids = result[:products].map { |p| p[:id] }
      expect(product_ids).not_to include(bundle.external_id)
      expect(product_ids).to include(product1.external_id, product2.external_id)
    end

    it "only returns products from the seller" do
      seller_product1 = create(:product, user: seller)
      seller_product2 = create(:product, user: seller)
      other_product = create(:product, user: other_seller)
      index_model_records(Link)

      result = described_class.new(bundle:, seller:).call

      product_ids = result[:products].map { |p| p[:id] }
      expect(product_ids).to include(seller_product1.external_id, seller_product2.external_id)
      expect(product_ids).not_to include(other_product.external_id)
    end

    it "excludes bundles, subscriptions, and calls" do
      regular_product = create(:product, user: seller)
      bundle_product = create(:product, :bundle, user: seller)
      subscription_product = create(:subscription_product, user: seller)
      call_product = create(:call_product, user: seller)
      index_model_records(Link)

      result = described_class.new(bundle:, seller:).call

      product_ids = result[:products].map { |p| p[:id] }
      expect(product_ids).to include(regular_product.external_id)
      expect(product_ids).not_to include(bundle_product.external_id, subscription_product.external_id, call_product.external_id)
    end

    it "only returns alive products" do
      alive_product = create(:product, user: seller)
      deleted_product = create(:product, user: seller, deleted_at: Time.current)
      index_model_records(Link)

      result = described_class.new(bundle:, seller:).call

      product_ids = result[:products].map { |p| p[:id] }
      expect(product_ids).to include(alive_product.external_id)
      expect(product_ids).not_to include(deleted_product.external_id)
    end

    it "supports query search" do
      product1 = create(:product, user: seller, name: "Amazing Product")
      product2 = create(:product, user: seller, name: "Great Bundle")
      product3 = create(:product, user: seller, name: "Another Product")
      index_model_records(Link)

      result = described_class.new(bundle:, seller:, query: "Amazing").call

      product_ids = result[:products].map { |p| p[:id] }
      expect(product_ids).to include(product1.external_id)
      expect(product_ids).not_to include(product2.external_id, product3.external_id)
    end

    it "paginates results" do
      create_list(:product, 15, user: seller)
      index_model_records(Link)

      result_page1 = described_class.new(bundle:, seller:, page: 1).call
      result_page2 = described_class.new(bundle:, seller:, page: 2).call

      expect(result_page1[:products].length).to eq(10)
      expect(result_page2[:products].length).to be <= 6
      expect(result_page1[:page]).to eq(1)
      expect(result_page2[:page]).to eq(2)
    end

    it "calculates has_more correctly" do
      create_list(:product, 15, user: seller)
      index_model_records(Link)

      result_page1 = described_class.new(bundle:, seller:, page: 1).call
      result_page2 = described_class.new(bundle:, seller:, page: 2).call

      expect(result_page1[:has_more]).to be(true)
      expect(result_page2[:has_more]).to be(false)
    end

    it "returns all products when all: true" do
      create_list(:product, 9, user: seller)
      index_model_records(Link)

      result = described_class.new(bundle:, seller:, all: true).call


      expect(result[:products].length).to eq(9)
      expect(result[:has_more]).to be(false)
    end

    it "returns empty results when seller has no products" do
      result = described_class.new(bundle:, seller:).call

      expect(result[:products]).to eq([])
      expect(result[:has_more]).to be(false)
      expect(result[:page]).to eq(1)
    end

    it "defaults page to 1 when page is invalid" do
      create_list(:product, 5, user: seller)
      index_model_records(Link)

      result = described_class.new(bundle:, seller:, page: 0).call

      expect(result[:page]).to eq(1)
    end

    it "returns total_count" do
      create_list(:product, 12, user: seller)
      index_model_records(Link)

      result = described_class.new(bundle:, seller:).call

      expect(result[:total_count]).to eq(12)
    end
  end
end
