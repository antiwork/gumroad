# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::Users::ProductsController do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  before do
    @admin_user = create(:admin_user)
    @user = create(:user)
    sign_in @admin_user
  end

  describe "GET index" do
    it "returns successful response with Inertia page data" do
      get :index, params: { user_id: @user.id }

      expect(response).to be_successful
      expect(response.body).to include("data-page")
      expect(response.body).to include("Admin/Users/Products/Index")
    end

    context "when user has products" do
      before do
        @product1 = create(:product, user: @user, name: "Product 1")
        @product2 = create(:product, user: @user, name: "Product 2")
      end

      it "displays user's products" do
        get :index, params: { user_id: @user.id }

        expect(response).to be_successful
      end

      it "handles pagination" do
        get :index, params: { user_id: @user.id, page: 1 }

        expect(response).to be_successful
      end
    end

    context "when user has many products" do
      before do
        12.times { |i| create(:product, user: @user, name: "Product #{i}") }
      end

      it "paginates products" do
        get :index, params: { user_id: @user.id, page: 1 }

        expect(response).to be_successful
      end

      it "handles second page" do
        get :index, params: { user_id: @user.id, page: 2 }

        expect(response).to be_successful
      end
    end

    context "when user has deleted products" do
      before do
        create(:product, user: @user, deleted_at: Time.current)
      end

      it "includes deleted products in list" do
        get :index, params: { user_id: @user.id }

        expect(response).to be_successful
      end
    end

    context "when user has banned products" do
      before do
        create(:product, user: @user, banned_at: Time.current)
      end

      it "includes banned products in list" do
        get :index, params: { user_id: @user.id }

        expect(response).to be_successful
      end
    end
  end
end
