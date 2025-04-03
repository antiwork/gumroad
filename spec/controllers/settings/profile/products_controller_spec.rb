# frozen_string_literal: true

require "shared_examples/authorize_called"

describe Settings::Profile::ProductsController do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  include_context "with user signed in as admin for seller"

  describe "GET show" do
    it_behaves_like "authorize called for action", :get, :show do
      let!(:record) { product }
      let(:policy_klass) { LinkPolicy }
      let(:request_params) { { id: product.external_id } }
    end

    it "returns props for that product" do
      get :show, params: { id: product.external_id }
      expect(response).to be_successful
      expect(response.parsed_body).to eq(ProductPresenter.new(product:, request:).product_props(seller_custom_domain_url: nil).as_json)
    end
  end
end
