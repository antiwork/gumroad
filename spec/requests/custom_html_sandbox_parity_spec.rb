# frozen_string_literal: true

require "spec_helper"

# The sandbox is spelled on four server surfaces — three wrapper iframes (profile,
# slugged page, product landing) and the CSP directive covering a direct top-level
# hit on /landing/embed, where the iframe attribute doesn't apply. A token present
# on three and missing on the fourth reaches sellers as "works on my product page
# but not my storefront", so these examples hit all four for real.
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
    it "permits downloads" do
      expect(sandbox).to include("allow-downloads")
    end

    it "still withholds same-origin and top navigation" do
      expect(sandbox).not_to include("allow-same-origin")
      expect(sandbox).not_to include("allow-top-navigation")
    end
  end

  # The editor previews frame these same /landing/embed documents from
  # app/javascript, and a sandbox attribute intersects with the response CSP: a
  # preview missing allow-downloads shows the seller their own download link
  # failing on a page that works once published.
  describe "the editor preview iframes" do
    %w[
      app/javascript/components/Profile/LandingPagePreview.tsx
      app/javascript/components/ProductEdit/LandingPagePreview/index.tsx
    ].each do |path|
      it "grants allow-downloads in #{path}" do
        source = Rails.root.join(path).read
        sandbox_attr = source[/sandbox="([^"]*)"/, 1]

        expect(sandbox_attr).to be_present
        expect(sandbox_attr).to include("allow-downloads")
      end
    end
  end
end
