# frozen_string_literal: true

require "spec_helper"

describe UpdateCachedSalesRelatedProductsInfosJob do
  describe "#perform" do
    before do
      Feature.activate(:update_sales_related_products_infos)
    end

    let(:product) { create(:product) }
    let(:product_2) { create(:product) }
    let(:product_3) { create(:product) }

    before do
      purchases = [
        build(:purchase, link: product, email: "joe@example.com"),
        build(:purchase, link: product_2, email: "joe@example.com"),
        build(:purchase, link: product_3, email: "joe@example.com"),
        build(:purchase, link: product, email: "alice@example.com"),
        build(:purchase, link: product_2, email: "alice@example.com"),
      ]

      # manually populate SRPIs
      purchases.each do |purchase|
        purchase.save!
        UpdateSalesRelatedProductsInfosJob.new.perform(purchase.id)
      end

      # sanity check
      expect(SalesRelatedProductsInfo.all).to match_array([
                                                            have_attributes(smaller_product_id: product.id, larger_product_id: product_2.id, sales_count: 2),
                                                            have_attributes(smaller_product_id: product.id, larger_product_id: product_3.id, sales_count: 1),
                                                            have_attributes(smaller_product_id: product_2.id, larger_product_id: product_3.id, sales_count: 1),
                                                          ])
    end

    it "creates or update cache record of related products sales counts" do
      # creates record
      expect do
        described_class.new.perform(product.id)
      end.to change(CachedSalesRelatedProductsInfo, :count).by(1)

      expect(CachedSalesRelatedProductsInfo.find_by(product:).normalized_counts).to eq(
        product_2.id => 2,
        product_3.id => 1,
      )

      # updates record
      purchase = create(:purchase, link: product_3, email: "alice@example.com")
      UpdateSalesRelatedProductsInfosJob.new.perform(purchase.id)

      expect do
        described_class.new.perform(product.id)
      end.not_to change(CachedSalesRelatedProductsInfo, :count)

      expect(CachedSalesRelatedProductsInfo.find_by(product:).normalized_counts).to eq(
        product_2.id => 2,
        product_3.id => 2,
      )
    end
  end
end
