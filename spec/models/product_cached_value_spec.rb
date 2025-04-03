# frozen_string_literal: true

describe ProductCachedValue do
  describe "#create" do
    it "is valid with a product" do
      expect(build(:product_cached_value, product: create(:product))).to be_valid
    end

    it "is invalid without a product" do
      expect(build(:product_cached_value, product: nil)).to_not be_valid
    end
  end

  describe "#expire!" do
    let(:product_cached_value) { create(:product_cached_value) }

    it "sets expired to true" do
      expect(product_cached_value.expired).to eq(false)

      product_cached_value.expire!

      expect(product_cached_value.expired).to eq(true)
    end
  end

  describe "#assign_cached_values" do
    let(:product_cached_value) { product.product_cached_values.create! }

    context "when the product resembles a product" do
      let(:product) { create(:product) }

      before do
        allow_any_instance_of(Link).to receive(:successful_sales_count).and_return(1.00)
        allow_any_instance_of(Link).to receive(:remaining_for_sale_count).and_return(2.00)
        allow_any_instance_of(Link).to receive(:total_usd_cents).and_return(100)
      end

      it "populates the attributes" do
        expect(product_cached_value.successful_sales_count).to eq(1.00)
        expect(product_cached_value.remaining_for_sale_count).to eq(2.00)
        expect(product_cached_value.monthly_recurring_revenue).to eq(0)
        expect(product_cached_value.revenue_pending).to eq(0)
        expect(product_cached_value.total_usd_cents).to eq(100)
      end
    end

    context "when the product resembles a membership" do
      let(:product) { create(:product, duration_in_months: 1) }

      before do
        allow_any_instance_of(Link).to receive(:successful_sales_count).and_return(3.00)
        allow_any_instance_of(Link).to receive(:remaining_for_sale_count).and_return(4.00)
        allow_any_instance_of(Link).to receive(:monthly_recurring_revenue).and_return(9_999_999.99)
        allow_any_instance_of(Link).to receive(:pending_balance).and_return(6)
        allow_any_instance_of(Link).to receive(:total_usd_cents).and_return(200)
      end

      it "populates the attributes" do
        expect(product_cached_value.successful_sales_count).to eq(3.00)
        expect(product_cached_value.remaining_for_sale_count).to eq(4.00)
        expect(product_cached_value.monthly_recurring_revenue).to eq(9_999_999.99)
        expect(product_cached_value.revenue_pending).to eq(6)
        expect(product_cached_value.total_usd_cents).to eq(200)
      end
    end
  end

  describe "scopes" do
    before do
      2.times { create(:product_cached_value) }
      create(:product_cached_value, :expired)
    end

    describe ".fresh" do
      it "returns an un-expired collection" do
        expect(described_class.fresh.count).to eq(2)
      end
    end

    describe ".expired" do
      it "returns an expired collection" do
        expect(described_class.expired.count).to eq(1)
      end
    end
  end
end
