# frozen_string_literal: true

require "spec_helper"

describe RegenerateSalesRelatedProductsInfosJob do
  describe "#perform" do
    let(:seller) { create(:named_seller) }
    let(:sample_product) { create(:product, user: seller) }
    let(:product1) { create(:product, name: "Product 1") }
    let(:product2) { create(:product, name: "Product 2") }
    let(:product3) { create(:product, name: "Product 3") }

    before do
      build_list(:purchase, 3, link: sample_product) do |purchase, i|
        purchase.update!(email: "customer#{i}@example.com")
      end
      build_list(:purchase, 3, link: product1) do |purchase, i|
        purchase.update!(email: "customer#{i}@example.com")
      end
      build_list(:purchase, 2, link: product2) do |purchase, i|
        purchase.update!(email: "customer#{i}@example.com")
      end
      create(:purchase, link: product3, email: "customer0@example.com")
    end

    it "creates SalesRelatedProductsInfo records for the product" do
      expect do
        described_class.new.perform(sample_product.id)
      end.to change { SalesRelatedProductsInfo.count }.by(3)

      expect(SalesRelatedProductsInfo.find_or_create_info(sample_product.id, product1.id).sales_count).to eq(3)
      expect(SalesRelatedProductsInfo.find_or_create_info(sample_product.id, product2.id).sales_count).to eq(2)
      expect(SalesRelatedProductsInfo.find_or_create_info(sample_product.id, product3.id).sales_count).to eq(1)

      SalesRelatedProductsInfo.find_or_create_info(sample_product.id, product1.id).delete # will be recreated
      SalesRelatedProductsInfo.find_or_create_info(sample_product.id, product2.id).update_column(:sales_count, 0) # will be updated

      expect do
        described_class.new.perform(sample_product.id)
      end.to change { SalesRelatedProductsInfo.count }.by(1)

      expect(SalesRelatedProductsInfo.find_or_create_info(sample_product.id, product1.id).sales_count).to eq(3)
      expect(SalesRelatedProductsInfo.find_or_create_info(sample_product.id, product2.id).sales_count).to eq(2)
      expect(SalesRelatedProductsInfo.find_or_create_info(sample_product.id, product3.id).sales_count).to eq(1)
    end
  end
end
