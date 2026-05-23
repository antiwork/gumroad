# frozen_string_literal: true

require "test_helper"

class CachedSalesRelatedProductsInfoTest < ActiveSupport::TestCase
  self.described_class = CachedSalesRelatedProductsInfo



  context_ CachedSalesRelatedProductsInfo do
  context_ "validations" do
  test "validates counts column format" do
        record = build(:cached_sales_related_products_info, counts: { "123" => "bar" })
        expect(record).to be_invalid
        expect(record.errors[:counts]).to be_present

        record = build(:cached_sales_related_products_info, counts: { "foo" => 1 })
        expect(record).to be_invalid
        expect(record.errors[:counts]).to be_present

        record = build(:cached_sales_related_products_info, counts: { "123" => 456 })
        expect(record).to be_valid
      end
    end

  context_ "#normalized_counts" do
  test "converts keys into integers" do
        # A json column forces keys to be strings, but we want them to be integers because they're product ids
        record = create(:cached_sales_related_products_info, counts: { 123 => 456 })
        record.reload
        expect(record.counts).to eq({ "123" => 456 })
        expect(record.normalized_counts).to eq({ 123 => 456 })
      end
    end
  end
end
