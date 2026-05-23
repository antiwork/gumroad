# frozen_string_literal: true

require "test_helper"

class RefundPolicyTest < ActiveSupport::TestCase
  self.described_class = RefundPolicy



  context_ RefundPolicy do
  context_ "validations" do
  test "validates presence" do
        staff_picked_product = StaffPickedProduct.new

        expect(staff_picked_product.valid?).to be false
        expect(staff_picked_product.errors.details[:product].first[:error]).to eq :blank
      end

  context_ "when there is a record for a given product" do
        let(:product) { create(:product, :staff_picked) }

  test "cannot create record with same product" do
          new_record = StaffPickedProduct.new(product:)

          expect(new_record.valid?).to be false
          expect(new_record.errors.details[:product].first[:error]).to eq :taken
        end
      end
    end
  end
end
