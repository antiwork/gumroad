# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::Affiliates::ProductsController, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  let(:affiliate_user) { create(:user) }
  let!(:published_product) { create(:product, name: "Published product") }
  let!(:unpublished_product) { create(:product, name: "Unpublished product", purchase_disabled_at: Time.current) }
  let!(:deleted_product) { create(:product, name: "Deleted product", deleted_at: Time.current) }
  let!(:banned_product) { create(:product, name: "Banned product", banned_at: Time.current) }
  let!(:alive_affiliate) { create(:direct_affiliate, affiliate_user:, products: [published_product, unpublished_product, deleted_product, banned_product]) }

  let!(:product_by_deleted_affiliate) { create(:product, name: "Product by deleted affiliate") }
  let!(:deleted_affiliate) { create(:direct_affiliate, affiliate_user:, products: [product_by_deleted_affiliate], deleted_at: Time.current) }

  before do
    sign_in admin_user
  end

  describe "GET index" do
    before do
      get :index, params: { affiliate_external_id: affiliate_user.external_id }
    end

    it "returns successful response with Inertia page data" do
      expect(response).to be_successful
      expect(inertia.component).to eq("Admin/Affiliates/Products/Index")
      expect(inertia.props[:products].map { _1[:external_id] }).to contain_exactly(published_product.external_id, unpublished_product.external_id)
      expect(inertia.props[:pagination]).to eq({ pages: 1, page: 1 })
    end
  end
end
