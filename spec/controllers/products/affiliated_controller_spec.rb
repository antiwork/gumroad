# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Products::AffiliatedController, inertia: true do
  include CurrencyHelper
  render_views

  it_behaves_like "inherits from Sellers::BaseController"

  # Users
  let(:creator) { create(:user) }
  let(:affiliate_user) { create(:affiliate_user) }

  # Products
  let(:product_one) { create(:product, name: "Creator 1 Product 1", user: creator, price_cents: 1000, purchase_disabled_at: 1.minute.ago) }
  let(:product_two) { create(:product, name: "Creator 1 Product 2", user: creator, price_cents: 2000) }
  let(:global_affiliate_eligible_product) { create(:product, :recommendable) }
  let(:affiliated_products) { [product_one, product_two, global_affiliate_eligible_product] }
  let(:affiliated_creators) { [creator, global_affiliate_eligible_product.user] }

  # Affiliates
  let(:global_affiliate) { affiliate_user.global_affiliate }
  let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller: creator, affiliate_basis_points: 1500, apply_to_all_products: true, products: [product_one, product_two], created_at: 1.hour.ago) }

  # Purchases
  let(:direct_sale_one) { create(:purchase_in_progress, seller: creator, link: product_one, affiliate: direct_affiliate) }
  let(:direct_sale_two) { create(:purchase_in_progress, seller: creator, link: product_one, affiliate: direct_affiliate) }
  let(:direct_sale_three) { create(:purchase_in_progress, seller: creator, link: product_two, affiliate: direct_affiliate) }
  let(:global_sale) { create(:purchase_in_progress, seller: global_affiliate_eligible_product.user, link: global_affiliate_eligible_product, affiliate: global_affiliate) }
  let(:affiliate_sales) { [direct_sale_one, direct_sale_two, direct_sale_three, global_sale] }

  include_context "with user signed in as admin for seller" do
    let(:seller) { affiliate_user }
  end

  it_behaves_like "authorize called for controller", Products::AffiliatedPolicy do
    let(:record) { :affiliated }
  end

  describe "GET index", :vcr do
    before do
      affiliate_sales.each do |purchase|
        purchase.process!
        purchase.update_balance_and_mark_successful!
      end
    end

    it "renders affiliated products and stats" do
      get :index

      expect(response).to have_http_status(:ok)
      expect(assigns[:title]).to eq("Products")

      expect(inertia).to render_component("Products/Affiliated/Index")

      # stats
      stats = inertia.props[:stats]
      expect(stats[:total_revenue]).to eq(affiliate_sales.sum(&:affiliate_credit_cents))
      expect(stats[:total_sales]).to eq(affiliate_user.affiliate_credits.count)
      expect(stats[:total_products]).to eq(affiliated_products.size)
      expect(stats[:total_affiliated_creators]).to eq(affiliated_creators.size)

      # products
      affiliated_products.each do |product|
        expect(inertia.props[:affiliated_products].any? { |p| p[:product_name] == product.name }).to be(true)
      end
    end

    context "pagination" do
      before { stub_const("AffiliatedProductsPresenter::PER_PAGE", 1) }

      it "returns paginated affiliate products" do
        get :index, format: :json

        expect(response).to be_successful
        expect(response.parsed_body["affiliated_products"].map { _1["product_name"] }).to contain_exactly product_one.name
        expect(response.parsed_body["pagination"]["page"]).to be 1
        expect(response.parsed_body["pagination"]["pages"]).to be 3

        get :index, params: { page: 2 }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliated_products"].map { _1["product_name"] }).to contain_exactly product_two.name
        expect(response.parsed_body["pagination"]["page"]).to be 2
        expect(response.parsed_body["pagination"]["pages"]).to be 3
      end

      it "paginates search results" do
        get :index, params: { page: 1, query: "Creator 1" }, format: :json

        expect(response).to be_successful
        expect(response.parsed_body["affiliated_products"].map { _1["product_name"] }).to contain_exactly product_one.name
        expect(response.parsed_body["pagination"]["page"]).to be 1
        expect(response.parsed_body["pagination"]["pages"]).to be 2

        get :index, params: { page: 2, query: "Creator 1" }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliated_products"].map { _1["product_name"] }).to contain_exactly product_two.name
        expect(response.parsed_body["pagination"]["page"]).to be 2
        expect(response.parsed_body["pagination"]["pages"]).to be 2
      end
    end

    context "search" do
      it "supports search by product name" do
        get :index, params: { page: 1, query: product_one.name }, format: :json

        expect(response).to be_successful
        expect(response.parsed_body["affiliated_products"].map { _1["product_name"] }).to contain_exactly product_one.name
      end

      it "returns an empty list if query does not match" do
        get :index, params: { page: 1, query: "non existent affiliated product" }, format: :json

        expect(response).to be_successful
        expect(response.parsed_body["affiliated_products"].size).to be 0
      end
    end

    shared_examples_for "sorting" do |sort_key, expected_results|
      it "sorts affiliated products by #{sort_key}" do
        get :index, params: { sort: { key: sort_key, direction: "asc" } }, format: :json

        expect(response).to be_successful
        result = response.parsed_body["affiliated_products"]
        expected_results.each do |key, values|
          expect(result.map { _1[key.to_s] }).to match_array(values)
        end

        get :index, params: { sort: { key: sort_key, direction: "desc" } }, format: :json

        expect(response).to be_successful
        result = response.parsed_body["affiliated_products"]
        expected_results.each do |key, values|
          expect(result.map { _1[key.to_s] }).to match_array(values.reverse)
        end
      end
    end

    it_behaves_like "sorting", "product_name", { product_name: ["Creator 1 Product 1", "Creator 1 Product 2", "The Works of Edgar Gumstein"] }
    it_behaves_like "sorting", "revenue", {
      product_name: ["Creator 1 Product 2", "Creator 1 Product 1", "The Works of Edgar Gumstein"],
      revenue: [249, 236, 0]
    }
    it_behaves_like "sorting", "commission", {
      product_name: ["The Works of Edgar Gumstein", "Creator 1 Product 1", "Creator 1 Product 2"],
      fee_percentage: [10, 15, 15]
    }
    it_behaves_like "sorting", "sales_count", {
      product_name: ["Creator 1 Product 1", "Creator 1 Product 2", "The Works of Edgar Gumstein"],
      sales_count: [0, 1, 2]
    }
  end
end
