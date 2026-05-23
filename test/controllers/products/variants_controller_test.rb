# frozen_string_literal: true

require "test_helper"
require "shared_examples/authorize_called"
require "shared_examples/sellers_base_controller_concern"

class ProductsVariantsControllerTest < ActionController::TestCase
  self.described_class = Products::VariantsController
  tests Products::VariantsController



  context_ Products::VariantsController do
    it_behaves_like "inherits from Sellers::BaseController"

    let(:seller) { create(:named_seller) }

    include_context "with user signed in as admin for seller"

  context_ "GET index" do
  context_ "authenticated as user with access to seller account" do
        let(:product) { create(:product, user: seller) }
        let(:circle_integration) { create(:circle_integration) }
        let(:discord_integration) { create(:discord_integration) }

        it_behaves_like "authorize called for action", :get, :index do
          let(:record) { product }
          let(:policy_klass) { Products::Variants::LinkPolicy }
          let(:request_params) { { link_id: product.unique_permalink } }
        end

  context_ "skus" do
          let(:product) { create(:physical_product, user: seller) }
          let!(:sku) { create(:sku, link: product, name: "Blue - large") }

  test "returns the SKUs" do
            get :index, format: :json, params: { link_id: product.unique_permalink }

            expect(response).to be_successful
            expect(response.parsed_body.map(&:deep_symbolize_keys)).to eq([sku.to_option_for_product])
          end
        end

  context_ "variants" do
          let(:product) { create(:product, user: seller, active_integrations: [circle_integration, discord_integration]) }
          let!(:category) { create(:variant_category, link: product, title: "Color") }
          let!(:blue_variant) { create(:variant, variant_category: category, name: "Blue", active_integrations: [circle_integration]) }
          let!(:green_variant) { create(:variant, variant_category: category, name: "Green", active_integrations: [discord_integration]) }

  test "returns the variants" do
            get :index, format: :json, params: { link_id: product.unique_permalink }

            expect(response).to be_successful
            expect(response.parsed_body.map(&:deep_symbolize_keys)).to eq([blue_variant, green_variant].map(&:to_option))
          end
        end

  context_ "no variants" do
          let(:product) { create(:product, user: seller) }

  test "returns an empty array" do
            get :index, format: :json, params: { link_id: product.unique_permalink }

            expect(response).to be_successful
            expect(response.parsed_body).to eq([])
          end
        end
      end

  context_ "for an invalid link ID" do
  test "returns an error message" do
          expect do
            get :index, format: :json, params: { link_id: "fake-id-123" }
          end.to raise_error(ActionController::RoutingError)
        end
      end
    end

  context_ "with product that doesn't belong to seller" do
      let(:product) { create(:product) }

  test "returns a 404" do
        expect do
          get :index, format: :json, params: { link_id: product.unique_permalink }
        end.to raise_error(ActionController::RoutingError)
      end
    end

  context_ "unauthenticated" do
      let(:product) { create(:product) }

      before do
        sign_out(seller)
      end

  test "returns a 404" do
        get :index, format: :json, params: { link_id: product.unique_permalink }

        expect(response).to have_http_status :not_found
        expect(response.parsed_body).to eq(
          "success" => false,
          "error" => "Not found"
        )
      end
    end
  end
end
