# frozen_string_literal: true

require "spec_helper"

# The navigate bridge is spelled in four places — the in-iframe click
# interceptor plus three trusted wrappers (profile, slugged page, product
# landing). Each one independently decides whether a URL may move the visitor's
# tab, so a path blessed on three surfaces and missing on the fourth reaches
# sellers as "My Downloads works on my storefront but not my product page".
# These examples hit all four for real.
describe "custom HTML page navigation allowlist", type: :request do
  let(:seller) { create(:user, username: "navallowlist", name: "Jane Doe") }
  let(:custom_html) { "<section><h1>Storefront</h1></section>" }

  before { Feature.activate_user(:custom_html_pages, seller) }

  # The wrapper is what actually assigns window.location, so it is the surface
  # that has to carry the predicate. The embed carries the interceptor half.
  {
    "profile wrapper" => ->(s, _p) { "http://#{s.subdomain}/" },
    "slugged page wrapper" => ->(s, _p) { "http://#{s.subdomain}/studio" },
    "product landing wrapper" => ->(_s, p) { "http://#{_s.subdomain}/l/#{p.unique_permalink}" },
    "landing embed (in-iframe interceptor)" => ->(_s, p) { "http://#{_s.subdomain}/l/#{p.unique_permalink}/landing/embed" },
  }.each do |surface, url_for|
    context "on the #{surface}" do
      let!(:product) { create(:product, user: seller, custom_html:) }
      let!(:page_record) { create(:user_page, pageable: seller, slug: "studio", title: "Studio", custom_html:) }

      before do
        seller.update!(custom_html:)
        get url_for.call(seller, product)
      end

      it "serves the shared decision helper rather than an open-coded hostname check" do
        expect(response).to be_successful
        expect(response.body).to include("function gumroadNavigationTarget(")
        expect(response.body).to include("gumroadNavigationTarget(url, STORE_HOSTNAMES)")
      end

      it "serves every blessed global path" do
        RendersCustomHtmlPages::GLOBAL_NAV_PATHS.each do |path|
          expect(response.body).to include(%("#{path}"))
        end
      end
    end
  end

  # Deliberately literals, not the constant: the examples above compare the
  # response against GLOBAL_NAV_PATHS, which moves with production and so
  # cannot notice a path being added. This fails if the set changes, which is
  # the point — widening what seller-authored HTML can do with the visitor's
  # tab should be a conscious edit. The bar for adding one: a path that acts on
  # a signed-in account, or that carries a redirect parameter, must not be
  # reachable, since seller HTML would otherwise pick the path.
  it "blesses exactly these two paths" do
    expect(RendersCustomHtmlPages::GLOBAL_NAV_PATHS).to eq(["/library", "/checkout"])
  end
end
