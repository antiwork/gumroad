# frozen_string_literal: false

require "spec_helper"

describe Purchases::ProductController do
  let(:purchase) { create(:purchase) }

  describe "GET show" do
    it "shows the product for the purchase" do
      get :show, params: { purchase_id: purchase.external_id }

      expect(response).to be_successful
      purchase_product_presenter = assigns(:purchase_product_presenter)
      expect(purchase_product_presenter.product).to eq(purchase.link)
      product_props = assigns(:product_props)
      expect(product_props).to eq(ProductPresenter.new(product: purchase.link, request:).product_props(seller_custom_domain_url: nil).deep_merge(purchase_product_presenter.product_props))
    end

    it "404s for an invalid purchase id" do
      expect do
        get :show, params: { purchase_id: "1234" }
      end.to raise_error(ActionController::RoutingError)
    end

    it "adds X-Robots-Tag response header to avoid page indexing" do
      get :show, params: { purchase_id: purchase.external_id }

      expect(response).to be_successful
      expect(response.headers["X-Robots-Tag"]).to eq("noindex")
    end
  end
end
