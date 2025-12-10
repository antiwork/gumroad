# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::Products::DetailsController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }

  before do
    sign_in admin_user
  end

  describe "GET show" do
    let(:product) { create(:product) }

    it "returns product details" do
      get :show, params: { product_external_id: product.external_id }, format: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["details"]).to be_present
    end
  end
end
