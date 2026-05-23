# frozen_string_literal: true

require "test_helper"
require "shared_examples/authorize_called"
require "shared_examples/sellers_base_controller_concern"

class SettingsProfileProductsControllerTest < ActionController::TestCase
  self.described_class = Settings::Profile::ProductsController
  tests Settings::Profile::ProductsController



  context_ Settings::Profile::ProductsController do
    it_behaves_like "inherits from Sellers::BaseController"

    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }

  context_ "GET show (unauthenticated)" do
  test "redirects to login" do
        get :show, params: { id: "any" }
        expect(response).to have_http_status(:found)
        expect(response.location).to include(login_path)
      end
    end

  context_ "when authenticated" do
      include_context "with user signed in as admin for seller"

  context_ "GET show" do
        it_behaves_like "authorize called for action", :get, :show do
          let!(:record) { product }
          let(:policy_klass) { LinkPolicy }
          let(:request_params) { { id: product.external_id } }
        end

  test "returns props for that product" do
          get :show, params: { id: product.external_id }
          expect(response).to be_successful
          expect(response.parsed_body).to eq(ProductPresenter.new(product:, request:).product_props(seller_custom_domain_url: nil).as_json)
        end
      end
    end
  end
end
