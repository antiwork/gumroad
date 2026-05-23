# frozen_string_literal: true

require "test_helper"
require "net/http"
require "shared_examples/authorized_oauth_v1_api_method"

class ApiV2VariantCategoriesControllerTest < ActionController::TestCase
  self.described_class = Api::V2::VariantCategoriesController
  tests Api::V2::VariantCategoriesController



  context_ Api::V2::VariantCategoriesController do
    before do
      @user = create(:user)
      @app = create(:oauth_application, owner: create(:user))
    end

  context_ "GET 'index'" do
      before do
        @product = create(:product, user: @user, description: "des", created_at: Time.current)
        @action = :index
        @params = { link_id: @product.external_id }
      end

      it_behaves_like "authorized oauth v1 api method"

  context_ "when logged in with view_public scope" do
        before do
          @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
          @params.merge!(access_token: @token.token)
        end

  test "shows the 0 variant categories" do
          get @action, params: @params
          expect(response.parsed_body["variant_categories"]).to be_empty
        end

  test "shows the 1 variant category" do
          variant_category = create(:variant_category, link: @product)
          get @action, params: @params
          expect(response.parsed_body).to eq({
            success: true,
            variant_categories: [variant_category]
          }.as_json(api_scopes: ["view_public"]))
        end
      end

  test "grants access with the account scope" do
        token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
        get @action, params: @params.merge(access_token: token.token)
        expect(response).to be_successful
      end
    end

  context_ "POST 'create'" do
      before do
        @product = create(:product, user: @user, description: "des", price_cents: 10_000, created_at: Time.current)
        @new_variant_category_params = { title: "hi" }
        @action = :create
        @params = { link_id: @product.external_id }.merge @new_variant_category_params
      end

      it_behaves_like "authorized oauth v1 api method"
      it_behaves_like "authorized oauth v1 api method only for edit_products scope"

  context_ "when logged in with edit_products scope" do
        before do
          @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
          @params.merge!(access_token: @token.token)
        end

  test "works if a new variant_category is passed in" do
          post @action, params: @params
          expect(@product.reload.variant_categories.alive.count).to eq(1)
          expect(@product.variant_categories.alive.first.title).to eq(@new_variant_category_params[:title])
        end

  test "returns the right response" do
          post @action, params: @params
          expect(response.parsed_body).to eq({
            success: true,
            variant_category: @product.variant_categories.alive.first
          }.as_json(api_scopes: ["edit_products"]))
        end

  context_ "there is already an offer code" do
          before do
            @first_variant_category = create(:variant_category, link: @product)
          end

  test "works if a new variant_category is passed in" do
            post @action, params: @params
            expect(@product.reload.variant_categories.alive.count).to eq(2)
            expect(@product.variant_categories.alive.first.title).to eq(@first_variant_category[:title])
            expect(@product.variant_categories.alive.second.title).to eq(@new_variant_category_params[:title])
          end
        end
      end
    end

  context_ "GET 'show'" do
      before do
        @product = create(:product, user: @user, description: "des", created_at: Time.current)
        @variant_category = create(:variant_category, link: @product)
        @action = :show
        @params = { link_id: @product.external_id, id: @variant_category.external_id }
      end

      it_behaves_like "authorized oauth v1 api method"

  context_ "when logged in" do
        before do
          @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
          @params.merge!(access_token: @token.token)
        end

  test "fails gracefully on bad id" do
          post @action, params: @params.merge(id: @variant_category.external_id + "++")
          expect(response.parsed_body).to eq({
            message: "The variant_category was not found.",
            success: false
          }.as_json)
        end

  test "returns the right response" do
          post @action, params: @params
          expect(response.parsed_body).to eq({
            success: true,
            variant_category: @product.reload.variant_categories.alive.first
          }.as_json(api_scopes: ["view_public"]))
        end
      end
    end

  context_ "PUT 'update'" do
      before do
        @product = create(:product, user: @user, description: "des", price_cents: 10_000, created_at: Time.current)
        @variant_category = create(:variant_category, title: "name1", link: @product)
        @new_variant_category_params = { title: "new_name1" }

        @action = :update
        @params = {
          link_id: @product.external_id,
          id: @variant_category.external_id
        }.merge @new_variant_category_params
      end

      it_behaves_like "authorized oauth v1 api method"
      it_behaves_like "authorized oauth v1 api method only for edit_products scope"

  context_ "when logged in with edit_products scope" do
        before do
          @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
          @params.merge!(access_token: @token.token)
        end

  test "fails gracefully on bad id" do
          post @action, params: @params.merge(id: @variant_category.external_id + "++")
          expect(response.parsed_body).to eq({
            message: "The variant_category was not found.",
            success: false
          }.as_json)
        end

  test "updates the variant category" do
          put @action, params: @params
          expect(@product.reload.variant_categories.alive.count).to eq(1)
          expect(@product.variant_categories.alive.first.title).to eq(@new_variant_category_params[:title])
        end

  test "returns the right response" do
          post @action, params: @params
          expect(response.parsed_body).to eq({
            success: true,
            variant_category: @product.reload.variant_categories.alive.first
          }.as_json(api_scopes: ["edit_products"]))
        end
      end
    end

  context_ "DELETE 'destroy'" do
      before do
        @product = create(:product, user: @user, description: "des", price_cents: 10_000, created_at: Time.current)
        @variant_category = create(:variant_category, link: @product)
        @action = :destroy
        @params = {
          link_id: @product.external_id,
          id: @variant_category.external_id
        }
      end

      it_behaves_like "authorized oauth v1 api method"
      it_behaves_like "authorized oauth v1 api method only for edit_products scope"

  context_ "when logged in with edit_products scope" do
        before do
          @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
          @params.merge!(access_token: @token.token)
        end

  test "fails gracefully on bad id" do
          post @action, params: @params.merge(id: @variant_category.external_id + "++")
          expect(response.parsed_body).to eq({
            message: "The variant_category was not found.",
            success: false
          }.as_json)
        end

  test "works if variant category id is passed" do
          delete @action, params: @params
          expect(@product.reload.variant_categories.alive.count).to eq(0)
        end

  test "returns the right response" do
          post @action, params: @params
          expect(response.parsed_body).to eq({
            success: true,
            message: "The variant_category was deleted successfully."
          }.as_json(api_scopes: ["edit_products"]))
        end
      end
    end
  end
end
