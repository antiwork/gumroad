# frozen_string_literal: true

require "spec_helper"

describe Admin::Products::StaffPicked::LinkPolicy do
  subject { described_class }

  let(:admin_user) { create(:admin_user) }
  let(:seller_context) { SellerContext.new(user: admin_user, seller: admin_user) }
  let(:product) { create(:product, :recommendable) }

  permissions :create? do
    context "when record does not exist" do
      it "grants access" do
        expect(subject).to permit(seller_context, product)
      end
    end

    context "when record exists and is deleted" do
      before do
        product.create_staff_picked_product!(deleted_at: Time.current)
      end

      it "grants access" do
        expect(subject).to permit(seller_context, product)
      end
    end

    context "when record exists and is not deleted" do
      before do
        product.create_staff_picked_product!
      end

      it "denies access" do
        expect(subject).not_to permit(seller_context, product)
      end
    end

    context "when product is not recommendable" do
      before do
        allow_any_instance_of(Link).to receive(:recommendable?).and_return(false)
      end

      it "denies access" do
        expect(subject).not_to permit(seller_context, product)
      end
    end
  end

  permissions :destroy? do
    context "when record exists and is not deleted" do
      before do
        product.create_staff_picked_product!
      end

      it "grants access" do
        expect(subject).to permit(seller_context, product)
      end
    end

    context "when record exists and is already deleted" do
      before do
        product.create_staff_picked_product!(deleted_at: Time.current)
      end

      it "denies access" do
        expect(subject).not_to permit(seller_context, product)
      end
    end
  end
end
