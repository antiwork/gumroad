# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "shared_examples/authorize_called"

describe Admin::Products::StaffPickedController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }

  before do
    sign_in admin_user
  end

  let(:product) { create(:product, :recommendable) }

  describe "POST create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:policy_klass) { Admin::Products::StaffPicked::LinkPolicy }
      let(:record) { product }
      let(:request_params) { { product_id: product.id } }
    end

    context "when product doesn't have an associated staff_picked_product" do
      it "creates a record" do
        expect do
          post :create, params: { product_id: product.id }, format: :json
        end.to change { StaffPickedProduct.all.count }.by(1)

        expect(product.reload.staff_picked?).to eq(true)
      end
    end

    context "when product has a deleted staff_picked_product record" do
      before do
        product.create_staff_picked_product!(deleted_at: Time.current)
      end

      it "updates the record as not deleted" do
        post :create, params: { product_id: product.id }, format: :json

        expect(product.reload.staff_picked?).to eq(true)
      end
    end
  end
end
