# frozen_string_literal: false

require "spec_helper"
require "inertia_rails/rspec"

describe Purchases::ProductController, inertia: true do
  let(:purchase) { create(:purchase) }

  describe "GET show" do
    it "shows the product for the purchase" do
      get :show, params: { purchase_id: purchase.external_id }

      expect(response).to be_successful
      expect(inertia.component).to eq("Purchases/ProductPage")

      purchase_product_presenter = PurchaseProductPresenter.new(purchase)
      expected_props = ProductPresenter.new(product: purchase.link, request:).product_props(seller_custom_domain_url: nil).deep_merge(purchase_product_presenter.product_props)
      expect(inertia.props[:product]).to eq(expected_props[:product])
      expect(inertia.props[:purchase]).to eq(expected_props[:purchase])
      expect(inertia.props[:discount_code]).to eq(expected_props[:discount_code])
      expect(inertia.props[:wishlists]).to eq(expected_props[:wishlists])
    end

    it "includes custom styles props" do
      get :show, params: { purchase_id: purchase.external_id }

      expect(response).to be_successful
      seller = purchase.link.user
      expect(inertia.props[:custom_styles]).to eq({
        background_color: seller.seller_profile.background_color,
        highlight_color: seller.seller_profile.highlight_color,
        font: seller.seller_profile.font
      })
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
