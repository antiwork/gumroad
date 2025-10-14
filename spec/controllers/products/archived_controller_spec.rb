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

    it "returns the user's archived products, no unarchived products or deleted products" do
      get :index

      expect(response).to have_http_status(:ok)
      expect(assigns[:title]).to eq("Archived products")

      expect(inertia).to render_component("Products/Archived/Index")

      memberships = inertia.props[:memberships]
      products = inertia.props[:products]

      expect(memberships.any? { |m| m[:name] == membership.name }).to be(false)
      expect(memberships.any? { |m| m[:name] == archived_membership.name }).to be(true)
      expect(memberships.any? { |m| m[:name] == deleted_membership.name }).to be(false)
      expect(memberships.any? { |m| m[:name] == other_membership.name }).to be(false)

      expect(products.any? { |p| p[:name] == product.name }).to be(false)
      expect(products.any? { |p| p[:name] == archived_product.name }).to be(true)
      expect(products.any? { |p| p[:name] == deleted_product.name }).to be(false)
      expect(products.any? { |p| p[:name] == other_product.name }).to be(false)
    end

    context "when there are no archived products" do
      before do
        archived_membership.update(archived: false)
        archived_product.update(archived: false)
      end

      it "redirects" do
        get :index

        expect(response).to redirect_to(products_url)
      end
    end
  end

  describe "GET products_paged" do
    it_behaves_like "authorize called for action", :get, :products_paged do
      let(:record) { Link }
      let(:policy_klass) { Products::Archived::LinkPolicy }
      let(:policy_method) { :index? }
    end

    it "returns the user's archived products and not the unarchived products" do
      get :products_paged, params: { page: 1 }, as: :json

      expect(response).to have_http_status(:ok)

      expect(response.parsed_body.keys).to include("pagination", "entries")
      expect(response.parsed_body["entries"].map { _1["name"] }).not_to include(product.name)
      expect(response.parsed_body["entries"].map { _1["name"] }).to include(archived_product.name)
      expect(response.parsed_body["entries"].map { _1["name"] }).not_to include(deleted_product.name)
      expect(response.parsed_body["entries"].map { _1["name"] }).not_to include(other_product.name)
    end

    it "returns empty entries for a query that doesn't match any products" do
      get :products_paged, params: { query: "invalid" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"]).to be_empty
    end

    it "returns products matching the search query" do
      get :products_paged, params: { page: 1, query: archived_product.name }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"].map { _1["name"] }).to include(archived_product.name)
      expect(response.parsed_body["entries"].map { _1["name"] }).not_to include(product.name)
    end

    describe "non-membership sorting + pagination", :elasticsearch_wait_for_refresh do
      before do
        stub_const("Products::ArchivedController::PER_PAGE", 2)
        Link.all.each(&:mark_deleted!)
      end

      include_context "with products and memberships", archived: true

      it_behaves_like "an API for sorting and pagination", :products_paged do
        let!(:default_order) { [product1, product3, product4, product2] }
        let!(:columns) do
          {
            "name" => [product1, product2, product3, product4],
            "successful_sales_count" => [product1, product2, product3, product4],
            "revenue" => [product3, product2, product1, product4],
            "display_price_cents" => [product3, product4, product2, product1]
          }
        end
        let!(:boolean_columns) { { "status" => [product3, product4, product1, product2] } }
      end
    end
  end

  describe "GET memberships_paged" do
    it_behaves_like "authorize called for action", :get, :memberships_paged do
      let(:record) { Link }
      let(:policy_klass) { Products::Archived::LinkPolicy }
      let(:policy_method) { :index? }
    end

    it "returns the user's archived memberships and not the unarchived memberships" do
      get :memberships_paged, params: { page: 1 }, as: :json

      expect(response).to have_http_status(:ok)

      expect(response.parsed_body.keys).to include("pagination", "entries")
      expect(response.parsed_body["entries"].map { _1["name"] }).not_to include(membership.name)
      expect(response.parsed_body["entries"].map { _1["name"] }).to include(archived_membership.name)
      expect(response.parsed_body["entries"].map { _1["name"] }).not_to include(deleted_membership.name)
      expect(response.parsed_body["entries"].map { _1["name"] }).not_to include(other_membership.name)
    end

    it "returns empty entries for a query that doesn't match any products" do
      get :memberships_paged, params: { query: "invalid" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"]).to be_empty
    end

    it "returns memberships matching the search query" do
      get :memberships_paged, params: { page: 1, query: archived_membership.name }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"].map { _1["name"] }).to include(archived_membership.name)
      expect(response.parsed_body["entries"].map { _1["name"] }).not_to include(membership.name)
    end

    describe "membership sorting + pagination", :elasticsearch_wait_for_refresh do
      before do
        stub_const("Products::ArchivedController::PER_PAGE", 2)
        Link.all.each(&:mark_deleted!)
      end

      include_context "with products and memberships", archived: true

      it_behaves_like "an API for sorting and pagination", :memberships_paged do
        let!(:default_order) { [membership2, membership3, membership4, membership1] }
        let!(:columns) do
          {
            "name" => [membership1, membership2, membership3, membership4],
            "successful_sales_count" => [membership4, membership1, membership3, membership2],
            "revenue" => [membership4, membership1, membership3, membership2],
            "display_price_cents" => [membership4, membership3, membership2, membership1]
          }
        end
        let!(:boolean_columns) { { "status" => [membership3, membership4, membership2, membership1] } }
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

    it "archives the product" do
      post :create, params: { id: membership.unique_permalink }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({ "success" => true })
      expect(membership.reload.archived?).to be(true)
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
