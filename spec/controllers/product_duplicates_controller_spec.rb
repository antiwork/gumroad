# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe ProductDuplicatesController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:file_params) do
    [
      { external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png" },
      { external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf" }
    ]
  end

  include_context "with user signed in as admin for seller"

  before do
    product.save_files!(file_params)
  end

  describe "POST create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:request_params) { { id: product.unique_permalink } }
      let(:record) { product }
      let(:policy_klass) { ProductDuplicates::LinkPolicy }
    end

    it "returns 404 when the id parameter is missing" do
      expect do
        post :create
      end.to raise_error(ActionController::RoutingError)
    end

    it "returns 404 when the id parameter is not the correct identifier for a product" do
      expect do
        post :create, params: { id: "invalid" }
      end.to raise_error(ActionController::RoutingError)
    end

    it "returns success when the id parameter is the correct identifier for a product" do
      post :create, params: { id: product.unique_permalink }

      expect(product.reload.is_duplicating).to be(true)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body).not_to have_key("error_message")
    end

    it "returns an error message when the product is already duplicating" do
      product.update!(is_duplicating: true)

      post :create, params: { id: product.unique_permalink }

      expect(response.parsed_body).to eq({ success: false, error_message: "Duplication in progress..." }.as_json)
    end

    it "queues DuplicateProductWorker when the id parameter is the correct identifier for a product" do
      post :create, params: { id: product.unique_permalink }

      expect(DuplicateProductWorker).to have_enqueued_sidekiq_job(product.id)
    end

    it "returns error_message when the current user is not the creator of the product" do
      different_user = create(:user)
      sign_in(different_user)
      expect do
        post :create, params: { id: product.unique_permalink }
      end.to raise_error(ActionController::RoutingError)
    end
  end

  describe "GET show" do
    before do
      product.update!(is_duplicating: false)
    end

    it_behaves_like "authorize called for action", :get, :show do
      let(:request_params) { { id: product.unique_permalink } }
      let(:record) { product }
      let(:policy_klass) { ProductDuplicates::LinkPolicy }
    end

    it "returns an error message when the product is still duplicating" do
      product.update!(is_duplicating: true)

      get :show, params: { id: product.unique_permalink }

      expect(response.parsed_body).to eq({ success: false, status: ProductDuplicatorService::DUPLICATING, error_message: "Duplication in progress..." }.as_json)
    end

    it "returns an error message when the product is not duplicating or recently duplicated" do
      expect(ProductDuplicatorService.new(product.id).recently_duplicated_product).to be(nil)

      get :show, params: { id: product.unique_permalink }

      expect(response.parsed_body).to eq({ success: false, status: ProductDuplicatorService::DUPLICATION_FAILED }.as_json)
    end

    it "successfully returns a recently duplicated product" do
      duplicated_product = ProductDuplicatorService.new(product.id).duplicate
      duplicated_product = DashboardProductsPagePresenter.new(
        pundit_user: SellerContext.new(user: user_with_role_for_seller, seller:),
        memberships: [],
        memberships_pagination: nil,
        products: [duplicated_product],
        products_pagination: nil
      ).page_props[:products].first

      get :show, params: { id: product.unique_permalink }

      expect(response.parsed_body).to eq({ success: true,
                                           status: ProductDuplicatorService::DUPLICATED,
                                           product:,
                                           duplicated_product:,
                                           is_membership: false }.as_json)
    end
  end
end
