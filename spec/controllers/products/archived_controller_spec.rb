# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "shared_examples/with_sorting_and_pagination"
require "inertia_rails/rspec"

describe Products::ArchivedController, inertia: true do
  render_views

  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  let!(:membership) { create(:membership_product, user: seller, name: "normal_membership") }
  let!(:archived_membership) { create(:membership_product, user: seller, name: "archived_membership", archived: true) }
  let!(:deleted_membership) { create(:membership_product, user: seller, name: "deleted_membership", archived: true, deleted_at: Time.current) }
  let!(:other_membership) { create(:membership_product, name: "other_membership") }

  let!(:product) { create(:product, user: seller, name: "normal_product") }
  let!(:archived_product) { create(:product, user: seller, name: "archived_product", archived: true) }
  let!(:deleted_product) { create(:product, user: seller, name: "deleted_product", archived: true, deleted_at: Time.current) }
  let!(:other_product) { create(:product, name: "other_product") }

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Link }
      let(:policy_klass) { Products::Archived::LinkPolicy }
      let(:policy_method) { :index? }
    end

    it "renders the Products/Archived/Index component with correct props" do
      get :index

      expect(response).to have_http_status(:ok)
      expect(assigns[:title]).to eq("Archived products")
      expect(inertia).to render_component("Products/Archived/Index")
      expect(inertia.props).to include(
        :can_create_product,
        :products_data,
        :memberships_data
      )
      expect(inertia.props[:products_data]).to include(:products, :pagination, :sort)
      expect(inertia.props[:memberships_data]).to include(:memberships, :pagination, :sort)
    end

    context "when there are no archived products" do
      before do
        archived_membership.update(archived: false)
        archived_product.update(archived: false)
      end

      it "redirects to products page" do
        get :index

        expect(response).to redirect_to(products_url)
      end
    end
  end

  describe "POST create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { membership }
      let(:request_params) { { id: membership.unique_permalink } }
      let(:policy_klass) { Products::Archived::LinkPolicy }
      let(:request_format) { :json }
    end

    it "archives and unpublishes the product" do
      expect(membership.purchase_disabled_at).to be_nil

      post :create, params: { id: membership.unique_permalink }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({ "success" => true })
      membership.reload
      expect(membership.archived?).to be(true)
      expect(membership.purchase_disabled_at).to be_present
    end

    it "does not change purchase_disabled_at on an already unpublished product" do
      original_disabled_at = 1.week.ago.floor
      membership.update!(purchase_disabled_at: original_disabled_at)

      post :create, params: { id: membership.unique_permalink }, as: :json

      expect(response).to have_http_status(:ok)
      membership.reload
      expect(membership.archived?).to be(true)
      expect(membership.purchase_disabled_at).to eq(original_disabled_at)
    end
  end

  describe "DELETE destroy" do
    before do
      membership.update!(archived: true)
    end

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { membership }
      let(:request_params) { { id: membership.unique_permalink } }
      let(:policy_klass) { Products::Archived::LinkPolicy }
      let(:request_format) { :json }
    end

    it "unarchives the product" do
      delete :destroy, params: { id: membership.unique_permalink }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({ "success" => true, "archived_products_count" => seller.archived_products_count })
      expect(membership.reload.archived?).to be(false)
    end
  end
end
