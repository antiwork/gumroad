# frozen_string_literal: true

require "spec_helper"

# The profile page renders its product sections through ProfileSectionsPresenter, which reads
# `request.query_parameters` directly rather than the controller's params. That copy never went
# through `format_search_params!`, so every one of these query strings reaches
# Link.search_options unsanitised and used to build a malformed Elasticsearch query.
describe "Profile page search params", :elasticsearch_wait_for_refresh, type: :request do
  let(:seller) { create(:user, username: "searchparamseller") }
  let!(:product) { create(:product, user: seller, name: "Georgia state outline") }

  before do
    create(:seller_profile_products_section, seller:, shown_products: [product.id])
    Link.import(refresh: true, force: true)
  end

  def get_profile(query = nil)
    get "#{seller.subdomain_with_protocol}/#{query}", headers: { "X-Inertia" => "true" }
  end

  it "renders when a visitor supplies a plain ?search= string" do
    get_profile("?search=georgia")

    expect(response).to be_successful
  end

  it "renders when a crafted nested ?search[] clause is supplied" do
    # A Hash passes the well-formed-clause guard but is still an arbitrary ES clause; slicing it
    # out at the presenter is what keeps it from reaching the query at all.
    get_profile("?search[range][total_fee_cents][gte]=1")

    expect(response).to be_successful
  end

  it "renders when ?search has no value at all" do
    # Parses to { "search" => nil }, which Rails' deep-munge does not compact out of a hash.
    get_profile("?search")

    expect(response).to be_successful
  end

  it "renders when a visitor supplies a comma-joined ?ids= list" do
    # format_search_params! splits this into an array; unsanitised it reaches ES as a bare
    # String where a `terms` clause requires an array.
    get_profile("?ids=1,2")

    expect(response).to be_successful
  end

  it "renders when a visitor supplies internal-only curated sort params" do
    get_profile("?sort=curated&curated_product_ids=abc")

    expect(response).to be_successful
  end

  it "still applies a legitimate visitor filter" do
    get_profile("?query=georgia")

    expect(response).to be_successful
  end
end
