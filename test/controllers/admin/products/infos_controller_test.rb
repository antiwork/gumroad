# frozen_string_literal: true

require "test_helper"
require "shared_examples/admin_base_controller_concern"

class AdminProductsInfosControllerTest < ActionController::TestCase
  self.described_class = Admin::Products::InfosController
  tests Admin::Products::InfosController



  context_ Admin::Products::InfosController do
    it_behaves_like "inherits from Admin::BaseController"

    let(:admin_user) { create(:admin_user) }

    before do
      sign_in admin_user
    end

  context_ "GET show" do
      let(:product) { create(:product) }

  test "returns product info" do
        get :show, params: { product_external_id: product.external_id }, format: :json

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["info"]).to be_present
      end
    end
  end
end
