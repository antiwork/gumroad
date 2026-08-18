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

  describe "GET search virtual default-products (gp#2196)" do
    let(:stubbed_search) do
      { total: 1, filetypes_data: [], tags_data: [], taxonomy_attributes_data: [], products: Link.none }
    end

    it "rejects default-products when the seller has profile sections and the flag is off" do
      create(:seller_profile_products_section, seller:)
      expect(controller).not_to receive(:search_products)

      get :search, params: { user_id: seller.external_id, section_id: ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID }

      expect(response.parsed_body).to include("total" => 0, "products" => [])
    end

    it "accepts default-products when the seller has profile sections and the storefront flag is on" do
      create(:seller_profile_products_section, seller:)
      Feature.activate_user(:default_product_page_to_storefront, seller)
      allow(controller).to receive(:search_products).and_return(stubbed_search)

      get :search, params: { user_id: seller.external_id, section_id: ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID }

      expect(response).to have_http_status(:ok)
      expect(controller).to have_received(:search_products)
      expect(response.parsed_body["total"]).to eq(1)
    end

    it "still rejects default-products when the flag is on for a different seller" do
      Feature.activate_user(:default_product_page_to_storefront, create(:user))
      create(:seller_profile_products_section, seller:)
      expect(controller).not_to receive(:search_products)

      get :search, params: { user_id: seller.external_id, section_id: ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID }

      expect(response.parsed_body).to include("total" => 0, "products" => [])
    end
  end
end
