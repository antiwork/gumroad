# frozen_string_literal: true

require "spec_helper"

describe Api::V2::SkusController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
  end

  describe "GET 'index'" do
    before do
      @product = create(:product, user: @user, description: "des", created_at: Time.current, skus_enabled: true)
      @params = { link_id: @product.external_id }
    end

    describe "when logged in with view_public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "shows the 0 skus" do
        get :index, params: @params
        expect(response.parsed_body["skus"]).to be_empty
      end

      it "shows the 1 sku" do
        category1 = create(:variant_category, title: "Size", link: @product)
        create(:variant, variant_category: category1, name: "Small")
        Product::SkusUpdaterService.new(product: @product).perform
        get :index, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          skus: [@product.skus.last]
        }.as_json(api_scopes: ["view_public"]))
      end

      it "shows the many skus" do
        category1 = create(:variant_category, title: "Size", link: @product)
        create(:variant, variant_category: category1, name: "Small")
        category2 = create(:variant_category, title: "Color", link: @product)
        create(:variant, variant_category: category2, name: "Red")
        create(:variant, variant_category: category2, name: "Blue")
        Product::SkusUpdaterService.new(product: @product).perform
        get :index, params: @params

        expect(response.parsed_body).to eq({
          success: true,
          skus: @product.skus.alive.to_a
        }.as_json(api_scopes: ["view_public"]))
      end

      it "shows the custom sku name" do
        category1 = create(:variant_category, title: "Size", link: @product)
        create(:variant, variant_category: category1, name: "Small")
        category2 = create(:variant_category, title: "Color", link: @product)
        create(:variant, variant_category: category2, name: "Red")
        create(:variant, variant_category: category2, name: "Blue")
        Product::SkusUpdaterService.new(product: @product).perform
        @product.skus.last.update_attribute(:custom_sku, "custom")
        get :index, params: @params

        expect(response.parsed_body).to eq({
          success: true,
          skus: @product.skus.alive.to_a
        }.as_json(api_scopes: ["view_public"]))
        expect(response.parsed_body["skus"][0].include?("custom_sku")).to eq(false)
        expect(response.parsed_body["skus"][1].include?("custom_sku")).to eq(true)
      end

      it "shows the variants for a physical product with SKUs disabled" do
        @product.update!(skus_enabled: false, is_physical: true, require_shipping: true)
        variant_category = create(:variant_category, title: "Color", link: @product)
        create(:variant, variant_category:, name: "Red")
        create(:variant, variant_category:, name: "Blue")

        get :index, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          skus: @product.alive_variants
        }.as_json(api_scopes: ["view_public"]))
      end
    end
  end
end
