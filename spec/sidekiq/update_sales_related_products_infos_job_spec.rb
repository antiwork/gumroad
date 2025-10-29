# frozen_string_literal: true

require "spec_helper"

describe UpdateSalesRelatedProductsInfosJob do
  describe "#perform" do
    before do
      Feature.activate(:update_sales_related_products_infos)
    end

    let(:seller) { create(:named_seller) }
    let(:product1) { create(:product, user: seller) }
    let(:product2) { create(:product, user: seller) }
    let!(:purchase) { create(:purchase, link: product2, email: "shared@gumroad.com") }
    let(:new_purchase) { create(:purchase, link: product1, email: "shared@gumroad.com") }

    context "when a SalesRelatedProductsInfo record exists" do
      let!(:sales_related_products_info) { create(:sales_related_products_info, smaller_product: product2, larger_product: product1, sales_count: 2) }

      context "when increment is false" do
        it "decrements the sales_count" do
          described_class.new.perform(new_purchase.id, false)
          expect(sales_related_products_info.reload.sales_count).to eq(1)
        end
      end

      context "when increment is true" do
        it "increments the sales_count" do
          described_class.new.perform(new_purchase.id)
          expect(sales_related_products_info.reload.sales_count).to eq(3)
        end
      end

      it "enqueues UpdateCachedSalesRelatedProductsInfosJob for the product and related products" do
        described_class.new.perform(new_purchase.id)

        expect(UpdateCachedSalesRelatedProductsInfosJob.jobs.count).to eq(2)
        expect(UpdateCachedSalesRelatedProductsInfosJob).to have_enqueued_sidekiq_job(product1.id)
        expect(UpdateCachedSalesRelatedProductsInfosJob).to have_enqueued_sidekiq_job(product2.id)
      end
    end

    context "when a SalesRelatedProductsInfo record doesn't exist" do
      it "creates a SalesRelatedProductsInfo record with sales_count set to 1" do
        expect do
          described_class.new.perform(new_purchase.id)
        end.to change(SalesRelatedProductsInfo, :count).by(1)
        created_sales_related_products_info = SalesRelatedProductsInfo.last

        new_sales_related_products_info = SalesRelatedProductsInfo.find_or_create_info(product1.id, product2.id)
        expect(new_sales_related_products_info).to eq(created_sales_related_products_info)
        expect(new_sales_related_products_info.sales_count).to eq(1)
      end
    end
  end
end
