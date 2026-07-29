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

    context "when the buyer owns more products than the per-purchase limit" do
      it "only counts the most recently purchased products and bounds the fan-out" do
        stub_const("#{described_class}::RELATED_PRODUCTS_PER_PURCHASE_LIMIT", 2)

        older_product = create(:product, user: seller)
        middle_product = create(:product, user: seller)
        newest_product = create(:product, user: seller)
        create(:purchase, link: older_product, email: "shared@gumroad.com")
        create(:purchase, link: middle_product, email: "shared@gumroad.com")
        create(:purchase, link: newest_product, email: "shared@gumroad.com")

        expect do
          described_class.new.perform(create(:purchase, link: product1, email: "shared@gumroad.com").id)
        end.to change(SalesRelatedProductsInfo, :count).by(2)

        # only the 2 most recent purchases are paired with the new sale; older ones are skipped
        expect(SalesRelatedProductsInfo.find_or_create_info(product1.id, newest_product.id).sales_count).to eq(1)
        expect(SalesRelatedProductsInfo.find_or_create_info(product1.id, middle_product.id).sales_count).to eq(1)

        # cache-refresh fan-out is capped too: purchased product + 2 related, not N+1
        expect(UpdateCachedSalesRelatedProductsInfosJob.jobs.count).to eq(3)
      end
    end

    context "when the buyer buys more products between the sale and its reversal" do
      # Pins the drift the cap introduces, rather than claiming it away. A reversal recomputes
      # "most recent N" at reversal time, so pairs the sale counted can fall out of the window
      # and keep their +1, while pairs that moved in are decremented (floored at 0 for a row
      # the reversal itself creates). Only reachable for buyers past the limit.
      #
      # Anchoring the window to the purchase id was tried and reverted: it did not recover a
      # related purchase refunded in the meantime either (that exclusion comes from the
      # eligibility scope, not the limit, and reproduces identically on main), so it added a
      # second window to reason about while fixing nothing.
      it "can leave a displaced pair over-counted" do
        stub_const("#{described_class}::RELATED_PRODUCTS_PER_PURCHASE_LIMIT", 2)

        first = create(:product, user: seller)
        second = create(:product, user: seller)
        create(:purchase, link: first, email: "shared@gumroad.com")
        create(:purchase, link: second, email: "shared@gumroad.com")

        sale = create(:purchase, link: product1, email: "shared@gumroad.com")
        described_class.new.perform(sale.id)

        expect(SalesRelatedProductsInfo.find_or_create_info(product1.id, first.id).sales_count).to eq(1)
        expect(SalesRelatedProductsInfo.find_or_create_info(product1.id, second.id).sales_count).to eq(1)

        # The buyer keeps shopping, pushing `first` and `second` out of the top 2.
        later_a = create(:product, user: seller)
        later_b = create(:product, user: seller)
        create(:purchase, link: later_a, email: "shared@gumroad.com")
        create(:purchase, link: later_b, email: "shared@gumroad.com")

        described_class.new.perform(sale.id, false)

        # Displaced pairs keep the sale's increment; the pairs now in the window floor at 0.
        expect(SalesRelatedProductsInfo.find_or_create_info(product1.id, first.id).sales_count).to eq(1)
        expect(SalesRelatedProductsInfo.find_or_create_info(product1.id, second.id).sales_count).to eq(1)
        expect(SalesRelatedProductsInfo.find_or_create_info(product1.id, later_a.id).sales_count).to eq(0)
        expect(SalesRelatedProductsInfo.find_or_create_info(product1.id, later_b.id).sales_count).to eq(0)
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
