# frozen_string_literal: true

require "spec_helper"

# Discover search (`GET /products/search`, LinksController#search) + `.map` behind
# safe-navigation on the controller's params — `&.` only guards nil, so any non-nil,
# non-Array `curated_product_ids` shape 500s a public product search (GUMROAD-R6).
# The value must be coerced to an Array in normalize_search_param_values! (same place as
# `ids`/`tags`) before the call site decodes it.
describe "Discover search params", :elasticsearch_wait_for_refresh, type: :request do
  let(:seller) { create(:user, username: "discoversearchseller") }
  let!(:product) { create(:product, user: seller, name: "Discover curated product") }

  before do
    Link.import(refresh: true, force: true)
  end

  def search(params)
    get "#{UrlService.discover_domain_with_protocol}/products/search", params: params
  end

  it "renders when curated_product_ids is an empty string (Discover pagination encoding of [])" do
    # Real client shape from GUMROAD-R6: Routes.products_search_path({ curated_product_ids: [] })
    # serializes to `curated_product_ids=`. Pre-fix this raised ''.map (NoMethodError).
    search(query: "after effects", sort: "most_reviewed", curated_product_ids: "", from: 10)

    expect(response).to have_http_status(:success)
  end

  it "renders when curated_product_ids arrives hash-indexed (Rails non-[] array encoding)" do
    # Real client shape from GUMROAD-R6: `sort=curated&curated_product_ids[0]=…&[1]=…`.
    # Pre-fix this raised on ActionController::Parameters#map (NoMethodError).
    first = ObfuscateIds.encrypt(product.id)
    search(sort: "most_reviewed", curated_product_ids: { "0" => first, "1" => ObfuscateIds.encrypt(product.id) })

    expect(response).to have_http_status(:success)
  end

  it "renders a comma-joined curated_product_ids string" do
    search(sort: "most_reviewed", curated_product_ids: "#{ObfuscateIds.encrypt(product.id)},#{ObfuscateIds.encrypt(product.id)}")

    expect(response).to have_http_status(:success)
  end

  it "still decodes a genuine curated sort that reaches the curated boost" do
    search(sort: ProductSortKey::CURATED, curated_product_ids: [ObfuscateIds.encrypt(product.id)])

    expect(response).to have_http_status(:success)
  end
end
