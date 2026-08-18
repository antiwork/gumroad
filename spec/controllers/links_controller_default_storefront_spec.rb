# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe LinksController, type: :controller, inertia: true do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  before { @request.host = URI.parse(seller.subdomain_with_protocol).host }

  describe "GET show default product page routing (gp#2196)" do
    it "renders the standalone product page when the storefront-default flag is off" do
      get :show, params: { id: product.unique_permalink }

      expect(inertia.component).to eq("Products/Show")
    end

    it "renders the storefront page when the storefront-default flag is on for the seller" do
      Feature.activate_user(:default_product_page_to_storefront, seller)

      get :show, params: { id: product.unique_permalink }

      expect(inertia.component).to eq("Products/Profile/Show")
      expect(inertia.props[:creator_profile]).to be_present
    end

    it "still renders the standalone page when an explicit discover layout is requested" do
      Feature.activate_user(:default_product_page_to_storefront, seller)

      get :show, params: { id: product.unique_permalink, layout: "discover" }

      expect(inertia.component).to eq("Products/Discover/Show")
    end

    it "still renders the iframe page for embed/overlay requests with the flag on" do
      Feature.activate_user(:default_product_page_to_storefront, seller)

      get :show, params: { id: product.unique_permalink, overlay: "true" }

      expect(inertia.component).to eq("Products/Iframe/Show")
    end
  end
end
