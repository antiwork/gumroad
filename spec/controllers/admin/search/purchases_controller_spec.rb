# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::Search::PurchasesController, type: :controller, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  before do
    sign_in create(:admin_user)
  end

  describe "#index" do
    let!(:email) { "user@example.com" }
    let(:ip_v4) { "203.0.113.42" }

    it "returns successful response with Inertia page data" do
      get :index, params: { query: email }

      expect(response).to be_successful
      expect(inertia.component).to eq("Admin/Search/Purchases/Index")
    end

    it "returns JSON response when requested" do
      purchase_1, purchase_2, purchase_3 = create_list(:purchase, 3, email:)
      get :index, params: { query: email, per_page: 2 }, format: :json

      expect(response).to be_successful
      expect(response.content_type).to match(%r{application/json})
      expect(response.parsed_body["purchases"]).to contain_exactly(hash_including("id" => purchase_1.id), hash_including("id" => purchase_2.id))
      expect(response.parsed_body["purchases"]).not_to include(hash_including("id" => purchase_3.id))
      expect(response.parsed_body["pagination"]).to be_present
    end

    it "redirects to the admin purchase page when one purchase is found" do
      purchase_by_email = create(:purchase, email:)
      purchase_by_ip = create(:purchase, ip_address: ip_v4)

      get :index, params: { query: email }
      expect(response).to redirect_to admin_purchase_path(purchase_by_email)

      get :index, params: { query: ip_v4 }
      expect(response).to redirect_to admin_purchase_path(purchase_by_ip)
    end

    it "returns purchases from AdminSearchService" do
      purchase_1 = create(:purchase, email:)
      purchase_2 = create(:gift, gifter_email: email, gifter_purchase: create(:purchase)).gifter_purchase
      purchase_3 = create(:gift, giftee_email: email, giftee_purchase: create(:purchase)).giftee_purchase

      expect_any_instance_of(AdminSearchService).to receive(:search_purchases).with(query: email, product_title_query: nil, purchase_status: nil).and_call_original
      get :index, params: { query: email }

      assert_response :success
      expect(assigns(:purchases)).to include(purchase_1, purchase_2, purchase_3)
    end

    describe "product_title_query" do
      let(:product_title_query) { "design" }
      let!(:product) { create(:product, name: "Graphic Design Course") }
      let!(:purchase) { create(:purchase, link: product, email: email) }

      before do
        create(:purchase, link: create(:product, name: "Different Product"))
      end

      context "when query is set" do
        it "filters by product title" do
          # Create another purchase with same email and same product to avoid redirect
          create(:purchase, email: email, link: product)

          expect_any_instance_of(AdminSearchService).to receive(:search_purchases).with(query: email, product_title_query:, purchase_status: nil).and_call_original

          get :index, params: { query: email, product_title_query: product_title_query }

          assert_response :success
          expect(assigns(:purchases)).to include(purchase)
        end
      end

      context "when query is not set" do
        it "ignores product_title_query" do
          expect_any_instance_of(AdminSearchService).to receive(:search_purchases).with(query: "", product_title_query:, purchase_status: nil).and_call_original

          get :index, params: { query: "", product_title_query: product_title_query }

          assert_response :success
          expect(assigns(:purchases)).to include(purchase)
        end
      end
    end

    describe "purchase_status" do
      let(:purchase_status) { "successful" }
      let!(:successful_purchase) { create(:purchase, purchase_state: "successful", email: email) }

      before do
        create(:purchase, purchase_state: "failed", email: email)
      end

      context "when query is set" do
        it "filters by purchase status" do
          # Create another purchase with same email and same status to avoid redirect
          create(:purchase, purchase_state: "successful", email: email)

          expect_any_instance_of(AdminSearchService).to receive(:search_purchases).with(query: email, product_title_query: nil, purchase_status:).and_call_original

          get :index, params: { query: email, purchase_status: purchase_status }

          assert_response :success
          expect(assigns(:purchases)).to include(successful_purchase)
        end
      end

      context "when query is not set" do
        it "ignores purchase_status" do
          expect_any_instance_of(AdminSearchService).to receive(:search_purchases).with(query: "", product_title_query: nil, purchase_status:).and_call_original

          get :index, params: { query: "", purchase_status: purchase_status }

          assert_response :success
          expect(assigns(:purchases)).to include(successful_purchase)
        end
      end
    end
  end
end
