# frozen_string_literal: true

require "spec_helper"

describe Iffy::Product::MarkCompliantService do
  describe "#perform" do
    let(:product) { create(:product, is_unpublished_by_admin: true) }
    let(:service) { described_class.new(product.external_id) }

    it "publishes the product" do
      service.perform

      product.reload
      expect(product.is_unpublished_by_admin).to be(false)
      expect(product.purchase_disabled_at).to be_nil
    end
  end
end
