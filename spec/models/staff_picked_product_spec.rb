# frozen_string_literal: true

require "spec_helper"

describe RefundPolicy do
  describe "validations" do
    it "validates presence" do
      staff_picked_product = StaffPickedProduct.new

      expect(staff_picked_product.valid?).to be false
      expect(staff_picked_product.errors.details[:product].first[:error]).to eq :blank
    end

    context "when there is a record for a given product" do
      let(:product) { create(:product, :staff_picked) }

      it "cannot create record with same product" do
        new_record = StaffPickedProduct.new(product:)

        expect(new_record.valid?).to be false
        expect(new_record.errors.details[:product].first[:error]).to eq :taken
      end
    end
  end
end
