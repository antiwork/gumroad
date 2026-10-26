# frozen_string_literal: true

require "spec_helper"

describe "Partner API", type: :request do
  let(:partner_application) { create(:oauth_application, owner: create(:user), is_partner: true, confidential: true, scopes: "partner_api") }
  let(:token) { create("doorkeeper/access_token", application: partner_application, resource_owner_id: nil, scopes: "partner_api") }

  let(:seller) { create(:user, name: "Ada Seller") }
  let(:other_seller) { create(:user) }
  let!(:partner_creator) { PartnerCreator.create!(oauth_application: partner_application, user: seller, external_user_id: "ext-1") }
  let!(:other_partner_creator) { PartnerCreator.create!(oauth_application: partner_application, user: other_seller, external_user_id: "ext-2") }

  before do
    host! "test.gumroad.com"
  end

  def get_products(params = {})
    get "/api/v2/partner/products", params: { access_token: token.token }.merge(params)
  end

  describe "authorization" do
    let!(:product) { create(:product, user: seller) }

    before { index_model_records(Link) }

    it "returns 401 without a token" do
      get "/api/v2/partner/products"

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 for a token without the partner_api scope" do
      account_token = create("doorkeeper/access_token", application: partner_application, resource_owner_id: nil, scopes: "account")

      get_products(access_token: account_token.token)

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 403 when the application is not a partner" do
      partner_application.update!(is_partner: false)

      get_products

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq("success" => false, "message" => "This endpoint is only available to partner applications.")
    end

    it "returns 403 when the application is not confidential" do
      partner_application.update!(confidential: false)

      get_products

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 403 when the application is deleted" do
      partner_application.mark_deleted!

      get_products

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 403 for a token issued on behalf of a seller" do
      seller_token = create("doorkeeper/access_token", application: partner_application, resource_owner_id: seller.id, scopes: "partner_api")

      get_products(access_token: seller_token.token)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v2/partner/products" do
    let!(:product) { create(:product, user: seller, name: "Texture Pack", price_cents: 1_500) }
    let!(:other_product) { create(:product, user: other_seller) }
    let!(:draft_product) { create(:product, user: seller, draft: true, purchase_disabled_at: Time.current) }
    let!(:archived_product) { create(:product, user: seller, archived: true) }
    let!(:banned_product) { create(:product, user: seller, banned_at: Time.current) }
    let!(:non_partner_product) { create(:product) }

    before do
      other_partner_application = create(:oauth_application, owner: create(:user), is_partner: true, confidential: true, scopes: "partner_api")
      PartnerCreator.create!(oauth_application: other_partner_application, user: non_partner_product.user, external_user_id: "ext-1")
      index_model_records(Link)
    end

    it "returns only the live products of the application's own creators" do
      get_products

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["products"].map { _1["id"] }).to match_array([product.external_id, other_product.external_id])
      expect(response.parsed_body).to include("success" => true, "total" => 2, "page" => 1, "per_page" => 20)
    end

    it "returns public listing fields and the creator's external user ID, without sales data" do
      get_products(external_user_id: "ext-1")

      listing = response.parsed_body["products"].sole
      expect(listing).to include(
        "id" => product.external_id,
        "name" => "Texture Pack",
        "price_cents" => 1_500,
        "rated_as_adult" => false,
        "creator" => include("external_user_id" => "ext-1", "name" => "Ada Seller"),
      )
      expect(listing.keys).not_to include("sales_count", "sales_usd_cents", "files", "rich_content")
    end

    it "excludes products that a seller with profile sections does not show" do
      hidden_product = create(:product, user: seller)
      create(:seller_profile_products_section, seller:, shown_products: [product.id])
      index_model_records(Link)

      get_products

      expect(response.parsed_body["products"].map { _1["id"] }).to match_array([product.external_id, other_product.external_id])
      expect(response.parsed_body["products"].map { _1["id"] }).not_to include(hidden_product.external_id)
    end

    it "includes a product that a seller features on the profile" do
      featured_product = create(:product, user: seller)
      create(:seller_profile_featured_product_section, seller:, featured_product_id: featured_product.id)
      index_model_records(Link)

      get_products(external_user_id: "ext-1")

      expect(response.parsed_body["products"].map { _1["id"] }).to eq([featured_product.external_id])
    end

    it "does not let another seller's section show a hidden product" do
      hidden_product = create(:product, user: seller)
      create(:seller_profile_products_section, seller:, shown_products: [product.id])
      create(:seller_profile_products_section, seller: other_seller, shown_products: [other_product.id, hidden_product.id])
      index_model_records(Link)

      get_products

      expect(response.parsed_body["products"].map { _1["id"] }).to match_array([product.external_id, other_product.external_id])
    end

    it "narrows to one creator by external user ID" do
      get_products(external_user_id: "ext-2")

      expect(response.parsed_body["products"].map { _1["id"] }).to eq([other_product.external_id])
    end

    it "returns no products for an unknown external user ID" do
      get_products(external_user_id: "unknown")

      expect(response.parsed_body).to include("products" => [], "total" => 0)
    end

    it "excludes a creator removed from the program" do
      other_partner_creator.mark_deleted!

      get_products

      expect(response.parsed_body["products"].map { _1["id"] }).to eq([product.external_id])
    end

    it "paginates" do
      get_products(sort: "newest", per_page: 1, page: 2)

      expect(response.parsed_body).to include("total" => 2, "page" => 2, "per_page" => 1)
      expect(response.parsed_body["products"].size).to eq(1)
    end

    it "rejects a page beyond the search result window" do
      get_products(per_page: 100, page: 101)

      expect(response).to have_http_status(:bad_request)
    end

    it "rejects an unsupported sort" do
      get_products(sort: "price_asc")

      expect(response).to have_http_status(:bad_request)
    end

    it "rejects an unknown category" do
      get_products(category: "not-a-category")

      expect(response).to have_http_status(:bad_request)
    end

    it "excludes a sold-out product that its seller hides" do
      create(:product, user: seller, hide_sold_out_variants: true, max_purchase_count: 0)
      index_model_records(Link)

      get_products

      expect(response.parsed_body["products"].map { _1["id"] }).to match_array([product.external_id, other_product.external_id])
      expect(response.parsed_body["total"]).to eq(2)
    end
  end

  describe "GET /api/v2/partner/categories" do
    it "returns the category paths that the category filter accepts" do
      get "/api/v2/partner/categories", params: { access_token: token.token }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["categories"]).to eq(Discover::TaxonomyPresenter.new.categories_for_api.as_json)
    end
  end

  describe "GET /api/v2/partner/creators/top" do
    let!(:product) { create(:product, user: seller) }
    let!(:other_product) { create(:product, user: other_seller) }

    before do
      2.times { create(:purchase, link: other_product) }
      create(:purchase, link: product)
      index_model_records(Purchase)
      index_model_records(Link)
    end

    it "returns the application's creators ranked by recent sales, without amounts" do
      get "/api/v2/partner/creators/top", params: { access_token: token.token }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["creators"].map { _1["external_user_id"] }).to eq(["ext-2", "ext-1"])
      expect(response.parsed_body["creators"].first.keys).to match_array(%w[external_user_id name avatar_url profile_url])
    end

    it "limits the number of creators" do
      get "/api/v2/partner/creators/top", params: { access_token: token.token, limit: 1 }

      expect(response.parsed_body["creators"].map { _1["external_user_id"] }).to eq(["ext-2"])
    end
  end
end
