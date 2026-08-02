# frozen_string_literal: true

require "spec_helper"

# The profile page renders its product sections through ProfileSectionsPresenter, which reads
# `request.query_parameters` directly rather than the controller's params. That copy never went
# through `format_search_params!`, so these query strings reach Link.search_options unsanitised
# unless the presenter slices and normalizes them itself.
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
    expect(response.body).to include(product.name)
  end

  it "ignores a crafted nested ?search[] range clause instead of applying it" do
    # The revenue oracle: unsliced, this range clause reaches Elasticsearch and filters the
    # product out, so whether the section renders answers "does this seller earn >= X?".
    # The product's total_fee_cents is 0, so a `gte: 1` clause would exclude it.
    get_profile("?search[range][total_fee_cents][gte]=1")

    expect(response).to be_successful
    expect(response.body).to include(product.name)
  end

  it "renders when ?search has no value at all" do
    # Parses to { "search" => nil }, which Rails' deep-munge does not compact out of a hash.
    get_profile("?search")

    expect(response).to be_successful
    expect(response.body).to include(product.name)
  end

  it "renders when a visitor supplies a comma-joined ?ids= list" do
    other_seller_product = create(:product, user: create(:user), name: "Someone else's product")

    get_profile("?ids=#{other_seller_product.id}")

    expect(response).to be_successful
    # :ids replaces the section's curated product list outright, so it staying out of the
    # allowlist is what keeps a visitor from renaming the section's contents.
    expect(response.body).to_not include(other_seller_product.name)
    expect(response.body).to include(product.name)
  end

  it "renders when a visitor supplies internal-only curated sort params" do
    get_profile("?sort=curated&curated_product_ids=abc")

    expect(response).to be_successful
  end

  it "renders when scalar filters arrive as arrays" do
    # search_options coerces these unconditionally (`.to_i`/`.to_f`), so an array shape raises
    # NoMethodError or 400s Elasticsearch unless normalized first.
    get_profile("?from[]=2&rating[]=4&query[]=a&min_price[]=1&size[]=3")

    expect(response).to be_successful
  end

  it "renders when scalar filters arrive nested more than one level deep" do
    # The nested scalars collapse to their innermost value, so `query` really filters here;
    # the point of the example is that the crafted shape renders instead of raising.
    get_profile("?query[][]=a&rating[][]=4&from[][]=2&size[][]=3&min_price[x]=1&sort[x]=y")

    expect(response).to be_successful
  end

  it "renders when list filters arrive nested" do
    get_profile("?tags[][]=a&filetypes[][]=pdf&ids[][]=1")

    expect(response).to be_successful
  end

  it "renders when a visitor asks for more results than the result window allows" do
    # search_options clamps `from` into 0..(MAX_RESULT_WINDOW - size), which raises on an
    # inverted range unless size is bounded first.
    get_profile("?size=20000")

    expect(response).to be_successful
    expect(response.body).to include(product.name)
  end

  it "renders when a visitor asks for a negative page size" do
    get_profile("?size=-1")

    expect(response).to be_successful
  end

  it "still applies a legitimate visitor filter" do
    get_profile("?query=zzzznomatch")

    expect(response).to be_successful
    # Asserting absence is what catches a filter key wrongly dropped from the allowlist: if
    # :query stopped reaching Elasticsearch, the unfiltered product would render.
    expect(response.body).to_not include(product.name)
  end
end
