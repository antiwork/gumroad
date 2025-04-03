# frozen_string_literal: true

require "spec_helper"

describe SalesRelatedProductsInfo do
  describe ".find_or_create_info" do
    let(:sales_related_products_info) { create(:sales_related_products_info) }

    context "when the info exists" do
      it "returns the info" do
        expect(described_class.find_or_create_info(sales_related_products_info.smaller_product_id, sales_related_products_info.larger_product_id)).to eq(sales_related_products_info)
        expect(described_class.find_or_create_info(sales_related_products_info.larger_product_id, sales_related_products_info.smaller_product_id)).to eq(sales_related_products_info)
      end
    end

    context "when the info does not exist" do
      let(:product1) { create(:product) }
      let(:product2) { create(:product) }

      it "creates the info" do
        expect do
          described_class.find_or_create_info(product1.id, product2.id)
        end.to change(described_class, :count).by(1)

        sales_related_products_info = described_class.last
        expect(sales_related_products_info.smaller_product_id).to eq(product1.id)
        expect(sales_related_products_info.larger_product_id).to eq(product2.id)
      end
    end
  end

  describe ".update_sales_counts" do
    it "upserts and increments/decrements the sales counts" do
      products = create_list(:product, 4)
      # use products[1] to check that the method handles smaller and larger ids correctly
      create(:sales_related_products_info, smaller_product: products[1], larger_product: products[2], sales_count: 5)

      described_class.update_sales_counts(product_id: products[1].id, related_product_ids: products.map(&:id) - [products[1].id], increment: true)

      # created records
      expect(described_class.find_by(smaller_product: products[0], larger_product: products[1]).sales_count).to eq(1)
      expect(described_class.find_by(smaller_product: products[1], larger_product: products[3]).sales_count).to eq(1)
      # updated record
      expect(described_class.find_by(smaller_product: products[1], larger_product: products[2]).sales_count).to eq(6)

      products << create(:product)
      described_class.update_sales_counts(product_id: products[1].id, related_product_ids: products.map(&:id) - [products[1].id], increment: false)

      # updated records
      expect(described_class.find_by(smaller_product: products[0], larger_product: products[1]).sales_count).to eq(0)
      expect(described_class.find_by(smaller_product: products[1], larger_product: products[2]).sales_count).to eq(5)
      expect(described_class.find_by(smaller_product: products[1], larger_product: products[3]).sales_count).to eq(0)
      # created record
      expect(described_class.find_by(smaller_product: products[1], larger_product: products[4]).sales_count).to eq(0)
    end
  end

  describe ".related_products" do
    it "returns related products sorted in descending order by sales count" do
      products = create_list(:product, 6)
      create(:sales_related_products_info, smaller_product: products[0], larger_product: products[3], sales_count: 7)
      create(:sales_related_products_info, smaller_product: products[1], larger_product: products[3], sales_count: 3)
      create(:sales_related_products_info, smaller_product: products[1], larger_product: products[2], sales_count: 7)
      create(:sales_related_products_info, smaller_product: products[2], larger_product: products[5], sales_count: 9)
      create(:sales_related_products_info, smaller_product: products[2], larger_product: products[3], sales_count: 5)
      create(:sales_related_products_info, smaller_product: products[2], larger_product: products[4], sales_count: 6)
      rebuild_srpis_cache

      # products[1] is first because it's related to products[3] (sales_count: 3) + products[2] (sales_count: 7) => 10
      # products[5] is second because it's related to products[2] (sales_count: 9) => 9
      # products[0] is third because it's related to products[3] (sales_count: 7) => 7
      # products[4] is fourth because it's related to products[2] (sales_count: 6) => 6
      expect(described_class.related_products([products[2].id, products[3].id])).to eq([
                                                                                         products[1], products[5], products[0], products[4]
                                                                                       ])

      # products[5] is first because it's related to products[2] (sales_count: 9) => 9
      # products[1] is second because it's related to products[2] (sales_count: 7) => 7
      # products[4] is third because it's related to products[2] (sales_count: 6) => 6
      expect(described_class.related_products([products[2].id], limit: 3)).to eq([
                                                                                   products[5], products[1], products[4]
                                                                                 ])

      # product with no related products
      expect(described_class.related_products([0])).to eq([])
      # empty product_ids
      expect(described_class.related_products([])).to eq([])
    end

    it "validates the arguments" do
      expect do
        described_class.related_products([1, "bad string", 2])
      end.to raise_error(ArgumentError, /must be an array of integers/)

      expect do
        described_class.related_products([1], limit: "bad string")
      end.to raise_error(ArgumentError, /must an integer/)
    end
  end

  describe ".related_product_ids_and_sales_counts" do
    it "validates the arguments" do
      expect do
        described_class.related_product_ids_and_sales_counts("bad string")
      end.to raise_error(ArgumentError, "product_id must be an integer")

      expect do
        described_class.related_product_ids_and_sales_counts(1, limit: "bad string")
      end.to raise_error(ArgumentError, "limit must be an integer")
    end

    it "returns a hash of related products and sales counts" do
      # [ [smaller_product_id, larger_product_id, sales_count], ...]
      data = [
        [1, 2, 12],
        [1, 3, 13],
        [1, 4, 100],
        [1, 5, 15],
        [2, 4, 24],
        [3, 4, 34],
        [4, 5, 45],
        [4, 6, 46],
        [4, 7, 47],
      ]
      data.each { described_class.insert!({ smaller_product_id: _1[0], larger_product_id: _1[1], sales_count: _1[2] }) }

      result = SalesRelatedProductsInfo.related_product_ids_and_sales_counts(4, limit: 3)
      expect(result).to eq(
        1 => 100,
        7 => 47,
        6 => 46,
      )
    end
  end

  describe "validation" do
    let!(:smaller_product) { create(:product) }
    let!(:larger_product) { create(:product) }

    context "when smaller_product_id is greater than larger_product_id" do
      it "adds an error" do
        expect(build(:sales_related_products_info, smaller_product: larger_product, larger_product: smaller_product)).not_to be_valid
      end
    end

    context "when smaller_product_id is equal to larger_product_id" do
      it "adds an error" do
        expect(build(:sales_related_products_info, smaller_product:, larger_product: smaller_product)).not_to be_valid
      end
    end

    context "when smaller_product_id is less than larger_product_id" do
      it "doesn't add an error" do
        expect(build(:sales_related_products_info, smaller_product:, larger_product:)).to be_valid
      end
    end
  end

  describe "scopes" do
    describe ".for_product_id" do
      it "returns matching records for a product id" do
        record = create(:sales_related_products_info)
        create(:sales_related_products_info)
        expect(described_class.for_product_id(record.smaller_product_id)).to eq([record])
        expect(described_class.for_product_id(record.larger_product_id)).to eq([record])
      end
    end
  end
end
