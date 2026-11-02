# frozen_string_literal: true

require "spec_helper"

describe "Partner API", type: :request do
  let(:partner_application) { create(:oauth_application, owner: create(:user), is_partner: true, confidential: true, scopes: "partner_api") }
  let(:token) { create("doorkeeper/access_token", application: partner_application, resource_owner_id: nil, scopes: "partner_api") }

  let(:seller) { create(:user, name: "Ada Seller") }
  let(:other_seller) { create(:user) }
  let!(:partner_seller) { create(:partner_seller, oauth_application: partner_application, user: seller, external_user_id: "ext-1") }
  let!(:other_partner_seller) { create(:partner_seller, oauth_application: partner_application, user: other_seller, external_user_id: "ext-2") }

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

    it "issues partner_api through the client credentials grant only to applications configured with it" do
      post "/oauth/token", params: { grant_type: "client_credentials", scope: "partner_api", client_id: partner_application.uid, client_secret: partner_application.secret }
      expect(response).to have_http_status(:ok)

      get_products(access_token: response.parsed_body.fetch("access_token"))
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["products"].map { _1["id"] }).to eq([product.external_id])

      self_serve_application = create(:oauth_application, owner: create(:user))
      post "/oauth/token", params: { grant_type: "client_credentials", scope: "partner_api", client_id: self_serve_application.uid, client_secret: self_serve_application.secret }
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_scope")
    end

    it "is not served on a seller's custom domain" do
      create(:custom_domain, user: seller, domain: "example.com")
      host! "example.com"

      get_products

      expect(response).to have_http_status(:not_found)
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
      create(:partner_seller, oauth_application: other_partner_application, user: non_partner_product.user, external_user_id: "ext-1")
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
      other_partner_seller.mark_deleted!

      get_products

      expect(response.parsed_body["products"].map { _1["id"] }).to eq([product.external_id])
    end

    it "paginates" do
      get_products(sort: "newest", per_page: 1, page: 2)

      expect(response.parsed_body).to include("total" => 2, "page" => 2, "per_page" => 1)
      expect(response.parsed_body["products"].size).to eq(1)
    end

    it "rejects array and hash pagination values" do
      get_products(page: ["2"])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq("success" => false, "message" => "page and per_page must be integers.")

      get_products(per_page: { "size" => "1" })

      expect(response).to have_http_status(:bad_request)
    end

    it "loads users only for the sellers it lists" do
      create_list(:partner_seller, 20, oauth_application: partner_application)
      users_loaded = 0
      count_users = ->(*, payload) { users_loaded += payload[:record_count] if payload[:class_name] == "User" }

      ActiveSupport::Notifications.subscribed(count_users, "instantiation.active_record") { get_products }

      expect(response.parsed_body["products"].size).to eq(2)
      expect(users_loaded).to be < 20
    end

    it "rejects a page beyond the search result window" do
      get_products(per_page: 100, page: 101)

      expect(response).to have_http_status(:bad_request)
    end

    it "serves the last partial page within the search result window" do
      search_response = double(records: double(ids: []), results: double(total: Link::MAX_RESULT_WINDOW))
      expect(Link).to receive(:search).with(hash_including(size: 1, from: Link::MAX_RESULT_WINDOW - 1)).and_return(search_response)

      get_products(per_page: 99, page: 102)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("total" => Link::MAX_RESULT_WINDOW, "next_page" => nil)
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
      expect(response.parsed_body["total"]).to eq(3)
    end

    it "continues past an empty page without changing the search total" do
      other_product.update!(created_at: 3.days.ago)
      product.update!(created_at: 2.days.ago)
      create(:product, user: seller, created_at: 1.day.ago, hide_sold_out_variants: true, max_purchase_count: 0)
      index_model_records(Link)

      get_products(sort: "newest", per_page: 1)

      expect(response.parsed_body).to include("products" => [], "total" => 3, "next_page" => 2)
      get_products(sort: "newest", per_page: 1, page: response.parsed_body["next_page"])
      expect(response.parsed_body).to include("total" => 3, "next_page" => 3)
      expect(response.parsed_body["products"].sole["id"]).to eq(product.external_id)
      get_products(sort: "newest", per_page: 1, page: response.parsed_body["next_page"])
      expect(response.parsed_body).to include("total" => 3, "next_page" => nil)
      expect(response.parsed_body["products"].sole["id"]).to eq(other_product.external_id)
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

    it "applies the hot_and_new age filter to the ranking" do
      other_product.update!(created_at: (Link::HOT_AND_NEW_PRODUCT_RECENTNESS + 1.day).ago)
      index_model_records(Link)

      get "/api/v2/partner/creators/top", params: { access_token: token.token, sort: "hot_and_new" }

      expect(response.parsed_body["creators"].map { _1["external_user_id"] }).to eq(["ext-1"])
    end

    it "rejects an unsupported sort" do
      get "/api/v2/partner/creators/top", params: { access_token: token.token, sort: "price_asc" }

      expect(response).to have_http_status(:bad_request)
    end

    it "rejects an array limit" do
      get "/api/v2/partner/creators/top", params: { access_token: token.token, limit: ["1"] }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq("success" => false, "message" => "limit must be an integer.")
    end

    it "limits the number of creators" do
      get "/api/v2/partner/creators/top", params: { access_token: token.token, limit: 1 }

      expect(response.parsed_body["creators"].map { _1["external_user_id"] }).to eq(["ext-2"])
    end
  end
end
