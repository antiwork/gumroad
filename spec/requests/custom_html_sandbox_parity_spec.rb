# frozen_string_literal: true

require "spec_helper"

# The sandbox is spelled in four places — three wrapper iframes (profile,
# slugged page, product landing) and the CSP directive that covers a direct
# top-level hit on /landing/embed, where the iframe attribute doesn't apply.
# They must stay identical: a token present on three surfaces and missing on
# the fourth is invisible in review and reaches sellers as "this works on my
# product page but not my storefront". These examples hit all four for real
# rather than asserting the constant against itself.
describe "custom HTML sandbox parity", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:user, username: "sandboxparity", name: "Jane Doe") }
  let(:sandbox) { RendersCustomHtmlPages::CUSTOM_HTML_SANDBOX }

  before { Feature.activate_user(:custom_html_pages, seller) }

  it "serves the same sandbox on the profile wrapper" do
    seller.update!(custom_html: "<section><h1>Profile</h1></section>")

    get "http://#{seller.subdomain}/"

    expect(response).to be_successful
    expect(response.body).to include(%(sandbox="#{sandbox}"))
  end

  it "serves the same sandbox on a slugged page wrapper" do
    create(:user_page, pageable: seller, slug: "studio", title: "Studio",
                       custom_html: "<section><h1>Studio</h1></section>")

    get "http://#{seller.subdomain}/studio"

    expect(response).to be_successful
    expect(response.body).to include(%(sandbox="#{sandbox}"))
  end

  it "serves the same sandbox on the product landing wrapper" do
    product = create(:product, user: seller, custom_html: "<section><h1>Product</h1></section>")

    get "http://#{seller.subdomain}/l/#{product.unique_permalink}"

    expect(response).to be_successful
    expect(response.body).to include(%(sandbox="#{sandbox}"))
  end

  it "serves the same sandbox as a CSP directive on the embed itself" do
    product = create(:product, user: seller, custom_html: "<section><h1>Product</h1></section>")

    get "http://#{seller.subdomain}/l/#{product.unique_permalink}/landing/embed"

    expect(response).to be_successful
    expect(response.headers["Content-Security-Policy"]).to include("sandbox #{sandbox}")
  end

  describe "the sandbox itself" do
    # Deliberately literals, not the constant: every other example here compares
    # a response against CUSTOM_HTML_SANDBOX, which moves with production and so
    # can't notice a token being added or dropped. These fail if the set changes,
    # which is the point — change it consciously.
    it "serves this exact token set on a rendered wrapper" do
      seller.update!(custom_html: "<section><h1>Profile</h1></section>")

      get "http://#{seller.subdomain}/"

      expect(response.body).to include(
        %(sandbox="allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox")
      )
    end

    # These are the tokens that would let seller-authored markup reach the buyer
    # or the page around it. Downloads are on this list by decision, not
    # oversight: the token would let a page hand a visitor a file from any host
    # under the seller's own subdomain, so a download link does nothing and the
    # docs say so instead.
    RendersCustomHtmlPages::CUSTOM_HTML_SANDBOX_FORBIDDEN_TOKENS.each do |token|
      it "withholds #{token}" do
        expect(sandbox).not_to include(token)
      end
    end

    # The wrapper attribute and the CSP directive are separate strings built from
    # the same list; a forbidden token could be appended to one of them without
    # touching the list at all.
    it "withholds them on the rendered wrapper and the embed CSP too" do
      product = create(:product, user: seller, custom_html: "<section><h1>Product</h1></section>")

      get "http://#{seller.subdomain}/l/#{product.unique_permalink}"
      wrapper_sandbox = response.body[/sandbox="([^"]*)"/, 1]

      get "http://#{seller.subdomain}/l/#{product.unique_permalink}/landing/embed"
      csp_sandbox = response.headers["Content-Security-Policy"][/sandbox ([^;]*)/, 1]

      RendersCustomHtmlPages::CUSTOM_HTML_SANDBOX_FORBIDDEN_TOKENS.each do |token|
        expect(wrapper_sandbox).not_to include(token)
        expect(csp_sandbox).not_to include(token)
      end
    end
  end
end
