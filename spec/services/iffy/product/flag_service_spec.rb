# frozen_string_literal: true

require "spec_helper"

describe Iffy::Product::FlagService do
  describe "#perform" do
    let(:product) { create(:product) }
    let(:service) { described_class.new(product.external_id) }

    it "unpublishes the product" do
      service.perform

      product.reload
      expect(product.is_unpublished_by_admin).to be(true)
      expect(product.purchase_disabled_at).to be_present
    end
  end
end
