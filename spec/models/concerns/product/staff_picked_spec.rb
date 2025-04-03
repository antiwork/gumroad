# frozen_string_literal: true

require "spec_helper"

describe Product::StaffPicked do
  let(:product) { create(:product) }

  describe "#staff_picked?" do
    context "when there is no staff_picked_product record" do
      it "returns false" do
        expect(product.staff_picked?).to eq(false)
      end
    end

    context "when there is a staff_picked_product record" do
      let!(:staff_picked_product) { product.create_staff_picked_product! }

      context "when the staff_picked_product record is not deleted" do
        it "returns true" do
          expect(product.staff_picked?).to eq(true)
        end
      end

      context "when the staff_picked_product record is deleted" do
        before do
          staff_picked_product.update_as_deleted!
        end

        it "returns false" do
          expect(product.staff_picked?).to eq(false)
        end
      end
    end
  end

  describe "#staff_picked_at" do
    context "when there is no staff_picked_product record" do
      it "returns nil" do
        expect(product.staff_picked_at).to eq(nil)
      end
    end

    context "when there is a staff_picked_product record" do
      let!(:staff_picked_product) { product.create_staff_picked_product! }

      before do
        staff_picked_product.touch
      end

      context "when the staff_picked_product record is not deleted" do
        it "returns correct timestamp" do
          expect(product.staff_picked_at).to eq(staff_picked_product.updated_at)
        end
      end

      context "when the staff_picked_product record is deleted" do
        before do
          staff_picked_product.update_as_deleted!
        end

        it "returns nil" do
          expect(product.staff_picked_at).to eq(nil)
        end
      end
    end
  end
end
