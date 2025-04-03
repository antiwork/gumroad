# frozen_string_literal: true

require "spec_helper"

describe ThirdPartyAnalyticsController do
  render_views

  before do
    @seller = create(:user)
    @product = create(:product, user: @seller)
    @purchase = create(:purchase, link: @product)
    @product_product_snippet = create(:third_party_analytic, user: @seller, link: @product, location: "product", analytics_code: "product product")
    @product_user_snippet = create(:third_party_analytic, user: @seller, link: nil, location: "product", analytics_code: "product user")
    @receipt_product_snippet = create(:third_party_analytic, user: @seller, link: @product, location: "receipt", analytics_code: "receipt product")
    @receipt_user_snippet = create(:third_party_analytic, user: @seller, link: nil, location: "receipt", analytics_code: "receipt user")
    @global_product_snippet = create(:third_party_analytic, user: @seller, link: @product, location: "all", analytics_code: "global product")
    @global_user_snippet = create(:third_party_analytic, user: @seller, link: nil, location: "all", analytics_code: "global user")
  end

  describe "index" do
    context "when location is product" do
      it "includes all applicable snippets" do
        get :index, params: { link_id: @product.unique_permalink, location: "product" }

        expect(response.body).to include @product_product_snippet.analytics_code
        expect(response.body).to include @product_user_snippet.analytics_code
        expect(response.body).to include @global_user_snippet.analytics_code
        expect(response.body).to include @global_product_snippet.analytics_code
        expect(response.body).to_not include @receipt_user_snippet.analytics_code
        expect(response.body).to_not include @receipt_product_snippet.analytics_code
      end
    end

    context "when location is receipt" do
      it "includes all applicable snippets" do
        get :index, params: { link_id: @product.unique_permalink, purchase_id: @purchase.external_id, location: "receipt" }

        expect(response.body).to include @receipt_user_snippet.analytics_code
        expect(response.body).to include @receipt_product_snippet.analytics_code
        expect(response.body).to include @global_user_snippet.analytics_code
        expect(response.body).to include @global_product_snippet.analytics_code
        expect(response.body).to_not include @product_product_snippet.analytics_code
        expect(response.body).to_not include @product_user_snippet.analytics_code
      end
    end

    it "successfully returns replaced analytics code" do
      @global_product_snippet.update_attribute(:analytics_code, "<img height='$VALUE' width='$CURRENCY' alt='' style='display:none' src='http://placehold.it/150x150' />")
      get :index, params: { link_id: @product.unique_permalink, purchase_id: @purchase.external_id, location: "receipt" }
      expect(response.body).to include "<img height='1' width='USD' alt='' style='display:none' src='http://placehold.it/150x150' />"
    end

    it "successfully returns analytics code with order id" do
      @global_product_snippet.update_attribute(:analytics_code, "<img height='$ORDER' width='$CURRENCY' alt='' style='display:none' src='http://placehold.it/150x150' />")
      get :index, params: { link_id: @product.unique_permalink, purchase_id: @purchase.external_id, location: "receipt" }
      expect(response.body).to include "<img height='#{@purchase.external_id}' width='USD' alt='' style='display:none' src='http://placehold.it/150x150' />"
    end

    it "doesn't return any analytics code if none exist for product or user" do
      new_product = create(:product)
      new_purchase = create(:purchase, link: new_product)
      get :index, params: { link_id: new_product.unique_permalink, purchase_id: new_purchase.external_id }
      expect(response.body).to_not include @product_product_snippet.analytics_code
      expect(response.body).to_not include @product_user_snippet.analytics_code
      expect(response.body).to_not include @global_user_snippet.analytics_code
      expect(response.body).to_not include @global_product_snippet.analytics_code
      expect(response.body).to_not include @receipt_user_snippet.analytics_code
      expect(response.body).to_not include @receipt_product_snippet.analytics_code
    end

    it "raises an e404 if the purchase does not belong to the product" do
      purchase = create(:purchase, link: create(:product))
      expect { get :index, params: { link_id: @product.unique_permalink, purchase_id: purchase.external_id } }.to raise_error(ActionController::RoutingError)
    end

    it "raises an e404 if the purchase does not exist" do
      expect { get :index, params: { link_id: @product.unique_permalink, purchase_id: "@purchase.external_id" } }.to raise_error(ActionController::RoutingError)
    end
  end
end
