# frozen_string_literal: true

require "spec_helper"

describe RecommendedProductsService do
  describe ".fetch" do
    let(:seller) { create(:user) }
    let!(:sample_product) { create(:product, user: seller) }
    let!(:product1) { create(:product, name: "Product 1", user: seller) }
    let!(:product2) { create(:product, name: "Product 2", user: seller) }
    let!(:product3) { create(:product, name: "Product 3") }
    let!(:product4) { create(:product, name: "Product 4", purchase_disabled_at: Time.current) }
    let!(:product5) { create(:product, name: "Product 5", deleted_at: Time.current) }
    let!(:product6) { create(:product, name: "Product 6", banned_at: Time.current) }

    before do
      SalesRelatedProductsInfo.find_or_create_info(sample_product.id, product1.id).update!(sales_count: 3)
      SalesRelatedProductsInfo.find_or_create_info(sample_product.id, product2.id).update!(sales_count: 2)
      SalesRelatedProductsInfo.find_or_create_info(sample_product.id, product3.id).update!(sales_count: 1)
      SalesRelatedProductsInfo.find_or_create_info(sample_product.id, product4.id).update!(sales_count: 1)
      SalesRelatedProductsInfo.find_or_create_info(sample_product.id, product5.id).update!(sales_count: 1)
      SalesRelatedProductsInfo.find_or_create_info(sample_product.id, product6.id).update!(sales_count: 1)
      rebuild_srpis_cache

      allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)
    end

    it "returns an ActiveRecord::Relation of products sorted by customer count and excludes non-alive products" do
      results = described_class.fetch(
        model: RecommendedProductsService::MODEL_SALES,
        ids: [sample_product.id],
      )
      expect(results).to be_a(ActiveRecord::Relation)
      expect(results.to_a).to eq([product1, product2, product3])
    end

    context "when `exclude_ids` is passed" do
      it "excludes products with the specified IDs" do
        expect(described_class.fetch(
          model: RecommendedProductsService::MODEL_SALES,
          ids: [sample_product.id],
          exclude_ids: [product1.id],
        ).to_a).to eq([product2, product3])
      end
    end

    context "when `user_ids` is passed" do
      it "only returns products that belong to the specified users" do
        expect(described_class.fetch(
          model: RecommendedProductsService::MODEL_SALES,
          ids: [sample_product.id],
          user_ids: [seller.id],
        ).to_a).to eq([product1, product2])
      end
    end

    context "when `number_of_results` is passed" do
      it "returns at most the specified number of products" do
        expect(described_class.fetch(
          model: RecommendedProductsService::MODEL_SALES,
          ids: [sample_product.id],
          number_of_results: 1,
        ).to_a).to eq([product1])
      end
    end
  end
end
