# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::VariantsController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
  end

  describe "GET 'index'" do
    before do
      @product = create(:product, user: @user, description: "des", created_at: Time.current)
      @variant_category = create(:variant_category, link: @product, title: "colors")
      @action = :index
      @params = {
        link_id: @product.external_id,
        variant_category_id: @variant_category.external_id
      }
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in with view_public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "shows the 0 variants in that variant category" do
        get @action, params: @params
        expect(response.parsed_body["variants"]).to eq []
      end

      it "shows the 1 variant in that variant category" do
        variant = create(:variant, variant_category: @variant_category, name: "red", price_difference_cents: 69)
        get @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          variants: [variant]
        }.as_json(api_scopes: ["view_public"]))
      end
    end
  end

  describe "POST 'create'" do
    before do
      @product = create(:product, user: @user, description: "des", created_at: Time.current)
      @variant_category = create(:variant_category, link: @product, title: "colors")

      @action = :create
      @params = {
        link_id: @product.external_id,
        variant_category_id: @variant_category.external_id,
        name: "blue",
        price_difference_cents: 100
      }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      describe "usd" do
        it "works if variants passed in" do
          post :create, params: @params
          expect(@product.reload.variant_categories.count).to eq 1
          expect(@product.variant_categories.first.title).to eq "colors"
          expect(@product.variant_categories.first.variants.alive.count).to eq 1
          expect(@product.variant_categories.first.variants.alive.first.name).to eq "blue"
          expect(@product.variant_categories.first.variants.alive.first.price_difference_cents).to eq 100
        end

        it "returns the right response" do
          post @action, params: @params
          expect(response.parsed_body).to eq({
            success: true,
            variant: @product.variant_categories.first.variants.first
          }.as_json(api_scopes: ["edit_products"]))
        end
      end

      describe "yen" do
        before do
          @user = create(:user, currency_type: "jpy")
          @product = create(:product, price_currency_type: "jpy", user: @user, description: "des", created_at: Time.current)
          @variant_category = create(:variant_category, link: @product, title: "colors")
          @params = {
            link_id: @product.external_id,
            variant_category_id: @variant_category.external_id,
            name: "blue",
            price_difference_cents: 100
          }
          @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
          @params.merge!(access_token: @token.token)
        end

        it "works if variants passed in" do
          post :create, params: @params
          expect(@product.reload.variant_categories.count).to eq 1
          expect(@product.variant_categories.first.title).to eq "colors"
          expect(@product.variant_categories.first.variants.alive.count).to eq 1
          expect(@product.variant_categories.first.variants.alive.first.name).to eq "blue"
          expect(@product.variant_categories.first.variants.alive.first.price_difference_cents).to eq 100
        end
      end
    end
  end

  describe "GET 'show'" do
    before do
      @user = create(:user)
      @product = create(:product, user: @user, description: "des", created_at: Time.current)
      @variant_category = create(:variant_category, link: @product, title: "colors")
      @variant = create(:variant, variant_category: @variant_category, name: "red", price_difference_cents: 69)

      @action = :show
      @params = {
        link_id: @product.external_id,
        variant_category_id: @variant_category.external_id,
        id: @variant.external_id
      }
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in with view_public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "fails gracefully on bad id" do
        get @action, params: @params.merge(id: @params[:id] + "++")
        expect(response.parsed_body).to eq({
          success: false,
          message: "The variant was not found."
        }.as_json)
      end

      it "returns the right response" do
        get @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          variant: @product.variant_categories.first.variants.first
        }.as_json(api_scopes: ["edit_products"]))
      end

      it "shows the variant in that variant category" do
        get @action, params: @params
        expect(response.parsed_body["variant"]).to eq(@product.variant_categories.first.variants.first.as_json(api_scopes: ["view_public"]))
      end
    end
  end

  describe "PUT 'update'" do
    before do
      @product = create(:product, user: @user, description: "des", created_at: Time.current)
      @variant_category = create(:variant_category, link: @product, title: "colors")
      @variant = create(:variant, variant_category: @variant_category, name: "red", price_difference_cents: 69)

      @action = :update
      @params = {
        link_id: @product.external_id,
        variant_category_id: @variant_category.external_id,
        id: @variant.external_id,
        name: "blue",
        price_difference_cents: 100
      }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      describe "usd" do
        it "works if variants passed in" do
          put @action, params: @params
          expect(@product.reload.variant_categories.count).to eq 1
          expect(@product.variant_categories.first.title).to eq "colors"
          expect(@product.variant_categories.first.variants.alive.count).to eq 1
          expect(@product.variant_categories.first.variants.alive.first.name).to eq "blue"
          expect(@product.variant_categories.first.variants.alive.first.price_difference_cents).to eq 100
        end

        it "returns the right response" do
          put @action, params: @params
          expect(response.parsed_body).to eq({
            success: true,
            variant: @product.variant_categories.first.variants.first
          }.as_json(api_scopes: ["edit_products"]))
        end

        it "fails gracefully on bad id" do
          put @action, params: @params.merge(id: @params[:id] + "++")
          expect(response.parsed_body).to eq({
            success: false,
            message: "The variant was not found."
          }.as_json)
        end
      end

      describe "yen" do
        before do
          @user = create(:user, currency_type: "jpy")
          @product = create(:product, price_currency_type: "jpy", user: @user, description: "des", created_at: Time.current)
          @variant_category = create(:variant_category, link: @product, title: "colors")
          @variant = create(:variant, variant_category: @variant_category, name: "red", price_difference_cents: 69)
          @params = {
            link_id: @product.external_id,
            variant_category_id: @variant_category.external_id,
            id: @variant.external_id,
            name: "blue",
            price_difference_cents: 100
          }
          @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
          @params.merge!(access_token: @token.token)
        end

        it "works if variants passed in" do
          put @action, params: @params
          expect(@product.reload.variant_categories.count).to eq 1
          expect(@product.variant_categories.first.title).to eq "colors"
          expect(@product.variant_categories.first.variants.alive.count).to eq 1
          expect(@product.variant_categories.first.variants.alive.first.name).to eq "blue"
          expect(@product.variant_categories.first.variants.alive.first.price_difference_cents).to eq 100
        end
      end
    end
  end

  describe "DELETE 'destroy'" do
    before do
      @product = create(:product, user: @user, description: "des", created_at: Time.current)
      @variant_category = create(:variant_category, link: @product, title: "colors")
      @variant = create(:variant, variant_category: @variant_category, name: "red", price_difference_cents: 69)

      @action = :destroy
      @params = {
        link_id: @product.external_id,
        variant_category_id: @variant_category.external_id,
        id: @variant.external_id
      }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "fails gracefully on bad id" do
        delete @action, params: @params.merge(id: @params[:id] + "++")
        expect(response.parsed_body).to eq({
          success: false,
          message: "The variant was not found."
        }.as_json)
      end

      describe "usd" do
        it "works if variants passed in" do
          delete @action, params: @params
          expect(@product.reload.variant_categories.count).to eq 1
          expect(@product.variant_categories.first.title).to eq "colors"
          expect(@product.variant_categories.first.variants.alive.count).to eq 0
        end

        it "returns the right response" do
          delete @action, params: @params
          expect(response.parsed_body).to eq({
            success: true,
            message: "The variant was deleted successfully."
          }.as_json(api_scopes: ["edit_products"]))
        end
      end
    end
  end
end
