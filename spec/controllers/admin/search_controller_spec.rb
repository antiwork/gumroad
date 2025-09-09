# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::SearchController do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  before do
    sign_in create(:admin_user)
  end

  describe "#users" do
    let!(:john) { create(:user, name: "John Doe", email: "johnd@gmail.com") }
    let!(:mary) { create(:user, name: "Mary Doe", email: "maryd@gmail.com", external_id: "12345") }
    let!(:derek) { create(:user, name: "Derek Sivers", email: "derek@sive.rs") }
    let!(:jane) { create(:user, name: "Jane Sivers", email: "jane@sive.rs") }

    it "searches for users with exact email" do
      get :users, params: { query: "johnd@gmail.com" }
      expect(response).to redirect_to admin_user_path(john)
    end

    it "searches for users with external_id" do
      get :users, params: { query: "12345" }
      expect(response).to redirect_to admin_user_path(mary)
    end

    it "searches for users with partial email" do
      get :users, params: { query: "sive.rs" }
      expect(response.body).to include("Derek Sivers")
      expect(response.body).to include("Jane Sivers")
    end

    it "searches for users with partial name" do
      get :users, params: { query: "doe" }
      expect(response.body).to include("John Doe")
      expect(response.body).to include("Mary Doe")
    end
  end

  describe "#purchases" do
    let!(:email) { "user@example.com" }
    let(:ip_v4) { "203.0.113.42" }

    it "redirects to the admin purchase page when one purchase is found" do
      purchase_by_email = create(:purchase, email:)
      purchase_by_ip = create(:purchase, ip_address: ip_v4)

      get :purchases, params: { query: email }
      expect(response).to redirect_to admin_purchase_path(purchase_by_email)

      get :purchases, params: { query: ip_v4 }
      expect(response).to redirect_to admin_purchase_path(purchase_by_ip)
    end

    it "returns purchases from AdminSearchService" do
      purchase_1 = create(:purchase, email:)
      purchase_2 = create(:gift, gifter_email: email, gifter_purchase: create(:purchase)).gifter_purchase
      purchase_3 = create(:gift, giftee_email: email, giftee_purchase: create(:purchase)).giftee_purchase

      expect_any_instance_of(AdminSearchService).to receive(:search_purchases).with(query: email, product_title_query: nil, purchase_status: nil).and_call_original
      get :purchases, params: { query: email }

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

          get :purchases, params: { query: email, product_title_query: product_title_query }

          assert_response :success
          expect(assigns(:purchases)).to include(purchase)
        end
      end

      context "when query is not set" do
        it "ignores product_title_query" do
          expect_any_instance_of(AdminSearchService).to receive(:search_purchases).with(query: "", product_title_query:, purchase_status: nil).and_call_original

          get :purchases, params: { query: "", product_title_query: product_title_query }

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

          get :purchases, params: { query: email, purchase_status: purchase_status }

          assert_response :success
          expect(assigns(:purchases)).to include(successful_purchase)
        end
      end

      context "when query is not set" do
        it "ignores purchase_status" do
          expect_any_instance_of(AdminSearchService).to receive(:search_purchases).with(query: "", product_title_query: nil, purchase_status:).and_call_original

          get :purchases, params: { query: "", purchase_status: purchase_status }

          assert_response :success
          expect(assigns(:purchases)).to include(successful_purchase)
        end
      end
    end
  end
end
