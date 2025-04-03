# frozen_string_literal: true

require "spec_helper"

describe AffiliatesHelper do
  describe "#affiliate_products_select_data" do
    let(:product) { create(:product) }
    let(:products) do
      [create(:product), product, create(:product)]
    end
    let(:direct_affiliate) { create(:direct_affiliate, products: [product]) }

    it "returns the ids of selected tags and the list of all tags" do
      tag_ids, tag_list = affiliate_products_select_data(direct_affiliate, products)

      expect(tag_ids).to eq([product.external_id])
      expect(tag_list).to eq(products.map { |product| { id: product.external_id, label: product.name } })
    end
  end
end
