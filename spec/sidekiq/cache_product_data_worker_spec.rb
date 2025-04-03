# frozen_string_literal: true

describe CacheProductDataWorker do
  describe "#perform" do
    before do
      @product = create(:product)
    end

    it "creates new product cache data" do
      expect do
        described_class.new.perform(@product.id)
      end.to change { ProductCachedValue.count }.by(1)

      product_cached_data = @product.reload.product_cached_values.last
      expect(product_cached_data.successful_sales_count).to eq(0)
      expect(product_cached_data.remaining_for_sale_count).to eq(nil)
      expect(product_cached_data.monthly_recurring_revenue).to eq(0.0)
      expect(product_cached_data.revenue_pending).to eq(0)
      expect(product_cached_data.total_usd_cents).to eq(0)
    end

    context "when data is already cached" do
      before do
        @product_cached_value = @product.product_cached_values.create!
      end

      it "expires the current cache and creates a new cached record" do
        expect do
          described_class.new.perform(@product.id)
        end.to change { @product_cached_value.reload.expired }.from(false).to(true)
        .and change { ProductCachedValue.count }.by(1)
      end
    end
  end
end
