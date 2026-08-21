# frozen_string_literal: true

require "spec_helper"

# Rails can parse indexed query keys into ActionController::Parameters; normalize
# curated IDs before the search path decrypts them.
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
    search(query: "after effects", sort: "most_reviewed", curated_product_ids: "", from: 10)

    expect(response).to have_http_status(:success)
  end

  it "renders when curated_product_ids arrives hash-indexed (Rails non-[] array encoding)" do
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
