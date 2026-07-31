# frozen_string_literal: true

require "spec_helper"

# The sandbox is spelled in four places — three wrapper iframes (profile,
# slugged page, product landing) and the CSP directive that covers a direct
# top-level hit on /landing/embed, where the iframe attribute doesn't apply.
# They must stay identical: a token present on three surfaces and missing on
# the fourth is invisible in review and reaches sellers as "this link works on
# my product page but not my storefront". These examples hit all four for real
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
    it "permits downloads, so a seller's link to a file isn't silently dropped" do
      # Without this token the browser cancels the download with no error the
      # seller or we can see, and target="_blank" can't route around it: the
      # escaped popup inherits the sandboxed initiator's download restriction.
      expect(sandbox).to include("allow-downloads")
    end

    it "still withholds same-origin and top navigation" do
      expect(sandbox).not_to include("allow-same-origin")
      expect(sandbox).not_to include("allow-top-navigation")
    end

    # Deliberately a literal, not the constant: every other example here compares
    # a response against CUSTOM_HTML_SANDBOX, which moves with production and so
    # can't notice a token being dropped. This one fails if the set ever changes,
    # which is the point — update it consciously.
    it "serves this exact token set on a rendered wrapper" do
      seller.update!(custom_html: "<section><h1>Profile</h1></section>")

      get "http://#{seller.subdomain}/"

      expect(response.body).to include(
        %(sandbox="allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox allow-downloads")
      )
    end
  end
end
