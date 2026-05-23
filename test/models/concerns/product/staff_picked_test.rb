# frozen_string_literal: true

require "test_helper"

class ProductStaffPickedTest < ActiveSupport::TestCase
  self.described_class = Product::StaffPicked



  context_ Product::StaffPicked do
    let(:product) { create(:product) }

  context_ "#staff_picked?" do
  context_ "when there is no staff_picked_product record" do
  test "returns false" do
          expect(product.staff_picked?).to eq(false)
        end
      end

  context_ "when there is a staff_picked_product record" do
        let!(:staff_picked_product) { product.create_staff_picked_product! }

  context_ "when the staff_picked_product record is not deleted" do
  test "returns true" do
            expect(product.staff_picked?).to eq(true)
          end
        end

  context_ "when the staff_picked_product record is deleted" do
          before do
            staff_picked_product.update_as_deleted!
          end

  test "returns false" do
            expect(product.staff_picked?).to eq(false)
          end
        end
      end
    end

  context_ "#staff_picked_at" do
  context_ "when there is no staff_picked_product record" do
  test "returns nil" do
          expect(product.staff_picked_at).to eq(nil)
        end
      end

  context_ "when there is a staff_picked_product record" do
        let!(:staff_picked_product) { product.create_staff_picked_product! }

        before do
          staff_picked_product.touch
        end

  context_ "when the staff_picked_product record is not deleted" do
  test "returns correct timestamp" do
            expect(product.staff_picked_at).to eq(staff_picked_product.updated_at)
          end
        end

  context_ "when the staff_picked_product record is deleted" do
          before do
            staff_picked_product.update_as_deleted!
          end

  test "returns nil" do
            expect(product.staff_picked_at).to eq(nil)
          end
        end
      end
    end
  end
end
