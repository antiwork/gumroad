# frozen_string_literal: true

require "spec_helper"

describe Api::V2::LinksController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, user: @user)
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
    # Product-level refund policies only apply when the account-level policy is off.
    @user.update!(refund_policy_enabled: false)
  end

  describe "PUT 'update' with refund policy params" do
    it "enables a product-level refund policy with a period and fine print" do
      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, refund_period: "none", refund_fine_print: "No refunds once downloaded." }

      expect(response).to have_http_status(:ok)
      @product.reload
      expect(@product.product_refund_policy_enabled).to be(true)
      expect(@product.product_refund_policy.max_refund_period_in_days).to eq(0)
      expect(@product.product_refund_policy.fine_print).to eq("No refunds once downloaded.")

      body = response.parsed_body
      expect(body.dig("product", "refund_policy")).to eq(
        "refund_period" => "none",
        "title" => "No refunds allowed",
        "fine_print" => "No refunds once downloaded.",
        "inherited" => false,
      )
    end

    it "updates the period without touching existing fine print" do
      @product.update!(product_refund_policy_enabled: true)
      @product.find_or_initialize_product_refund_policy.update!(max_refund_period_in_days: 0, fine_print: "Existing fine print.")

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, refund_period: "30" }

      expect(response).to have_http_status(:ok)
      policy = @product.reload.product_refund_policy
      expect(policy.max_refund_period_in_days).to eq(30)
      expect(policy.fine_print).to eq("Existing fine print.")
    end

    it "updates only the fine print when the product already has a policy" do
      @product.update!(product_refund_policy_enabled: true)
      @product.find_or_initialize_product_refund_policy.update!(max_refund_period_in_days: 14)

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, refund_fine_print: "Updated fine print." }

      expect(response).to have_http_status(:ok)
      policy = @product.reload.product_refund_policy
      expect(policy.max_refund_period_in_days).to eq(14)
      expect(policy.fine_print).to eq("Updated fine print.")
    end

    it "rejects fine print alone when no product-level policy exists" do
      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, refund_fine_print: "Orphan fine print." }

      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to include("refund_fine_print requires refund_period")
      expect(@product.reload.product_refund_policy_enabled).to be(false)
    end

    it "clears the fine print when passed an empty string" do
      @product.update!(product_refund_policy_enabled: true)
      @product.find_or_initialize_product_refund_policy.update!(max_refund_period_in_days: 7, fine_print: "Old fine print.")

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, refund_fine_print: "" }

      expect(response).to have_http_status(:ok)
      expect(@product.reload.product_refund_policy.fine_print).to be_nil
    end

    it "disables the product override when refund_period is inherit" do
      @product.update!(product_refund_policy_enabled: true)
      @product.find_or_initialize_product_refund_policy.update!(max_refund_period_in_days: 0)

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, refund_period: "inherit" }

      expect(response).to have_http_status(:ok)
      expect(@product.reload.product_refund_policy_enabled).to be(false)
      expect(response.parsed_body.dig("product", "refund_policy")).to eq(
        "refund_period" => "inherit",
        "title" => nil,
        "fine_print" => nil,
        "inherited" => true,
      )
    end

    it "rejects fine print combined with inherit" do
      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, refund_period: "inherit", refund_fine_print: "Nope." }

      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to include("cannot be set when refund_period is 'inherit'")
    end

    it "rejects an invalid refund period" do
      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, refund_period: "45" }

      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to eq("refund_period must be one of: inherit, none, 7, 14, 30, 183.")
    end

    it "rejects refund policy params when the account-level policy is in effect" do
      @user.update!(refund_policy_enabled: true)

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, refund_period: "none" }

      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to include("account-level refund policy applies to all products")
      expect(@product.reload.product_refund_policy_enabled).to be(false)
    end
  end

  describe "POST 'create' with refund policy params" do
    it "creates a product with a product-level refund policy" do
      post :create, params: { format: :json, access_token: @token.token, name: "No Refunds Pack", price: 500, refund_period: "none", refund_fine_print: "All sales final." }

      expect(response).to have_http_status(:ok)
      product = Link.last
      expect(product.product_refund_policy_enabled).to be(true)
      expect(product.product_refund_policy.max_refund_period_in_days).to eq(0)
      expect(product.product_refund_policy.fine_print).to eq("All sales final.")
      expect(response.parsed_body.dig("product", "refund_policy", "refund_period")).to eq("none")
    end

    it "treats refund_period inherit as a no-op on create" do
      post :create, params: { format: :json, access_token: @token.token, name: "Default Policy Pack", price: 500, refund_period: "inherit" }

      expect(response).to have_http_status(:ok)
      product = Link.last
      expect(product.product_refund_policy_enabled).to be(false)
      expect(response.parsed_body.dig("product", "refund_policy", "refund_period")).to eq("inherit")
    end

    it "rejects an invalid refund period without creating the product" do
      expect do
        post :create, params: { format: :json, access_token: @token.token, name: "Bad Policy Pack", price: 500, refund_period: "forever" }
      end.not_to change(Link, :count)

      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to eq("refund_period must be one of: inherit, none, 7, 14, 30, 183.")
    end

    it "rejects refund policy params when the account-level policy is in effect" do
      @user.update!(refund_policy_enabled: true)

      expect do
        post :create, params: { format: :json, access_token: @token.token, name: "Blocked Policy Pack", price: 500, refund_period: "none" }
      end.not_to change(Link, :count)

      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to include("account-level refund policy applies to all products")
    end
  end

  describe "GET 'show'" do
    let(:read_token) { create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public") }

    it "includes the product refund policy when the override is enabled" do
      @product.update!(product_refund_policy_enabled: true)
      @product.find_or_initialize_product_refund_policy.update!(max_refund_period_in_days: 30, fine_print: "Reviewed within 2 business days.")

      get :show, params: { format: :json, access_token: read_token.token, id: @product.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("product", "refund_policy")).to eq(
        "refund_period" => "30",
        "title" => "30-day money back guarantee",
        "fine_print" => "Reviewed within 2 business days.",
        "inherited" => false,
      )
    end

    it "reports inherit when no override is enabled" do
      get :show, params: { format: :json, access_token: read_token.token, id: @product.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("product", "refund_policy", "refund_period")).to eq("inherit")
    end

    it "omits refund_policy from the slim list endpoint" do
      get :index, params: { format: :json, access_token: read_token.token }

      expect(response).to have_http_status(:ok)
      product_json = response.parsed_body["products"].find { |p| p["id"] == @product.external_id }
      expect(product_json).not_to have_key("refund_policy")
    end
  end
end
