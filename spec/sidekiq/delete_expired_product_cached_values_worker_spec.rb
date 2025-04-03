# frozen_string_literal: true

require "spec_helper"

describe DeleteExpiredProductCachedValuesWorker do
  describe "#perform" do
    it "deletes expired rows, except the latest one per product" do
      product_1 = create(:product)
      create_list(:product_cached_value, 3, :expired, product: product_1) # should delete 3 of them
      create(:product_cached_value, product: product_1) # should not be deleted

      product_2 = create(:product)
      create_list(:product_cached_value, 2, :expired, product: product_2) # should delete 1 of them

      product_3 = create(:product)
      create(:product_cached_value, :expired, product: product_3) # should be deleted
      create(:product_cached_value, product: product_3) # should not be deleted

      create(:product_cached_value, :expired) # should not be deleted
      create(:product_cached_value) # should not be deleted

      records = ProductCachedValue.order(:id).to_a

      stub_const("#{described_class}::QUERY_BATCH_SIZE", 2)

      expect do
        described_class.new.perform
      end.to change { ProductCachedValue.count }.by(-5)

      [0, 1, 2, 4, 6].each do |index|
        expect { records[index].reload }.to raise_error(ActiveRecord::RecordNotFound)
      end
      [3, 5, 7, 8, 9].each do |index|
        expect(records[index].reload).to be_instance_of(ProductCachedValue)
      end
    end
  end
end
